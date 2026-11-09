"""Cloudflare D1 over its HTTP API (CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_D1_DATABASE_ID, CLOUDFLARE_API_TOKEN).
Same behaviour as Trading's util/strategy_pnl_d1.D1: raises on failure, retries transient errors
(network, HTTP 5xx) three times, never retries a statement the server rejected."""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Sequence

from .config import require

NAMES = ('CLOUDFLARE_ACCOUNT_ID', 'CLOUDFLARE_D1_DATABASE_ID', 'CLOUDFLARE_API_TOKEN')


class D1:
    def __init__(self, env_file: Path | str | None = None, database_id: str | None = None,
                 timeout: float = 30, attempts: int = 3, pause: float = 2.0):
        c = require(NAMES, env_file)
        db = database_id or c['CLOUDFLARE_D1_DATABASE_ID']
        self.url = f"https://api.cloudflare.com/client/v4/accounts/{c['CLOUDFLARE_ACCOUNT_ID']}/d1/database/{db}/query"
        self.headers = {'Authorization': f"Bearer {c['CLOUDFLARE_API_TOKEN']}", 'Content-Type': 'application/json'}
        self.timeout, self.attempts, self.pause = timeout, attempts, pause

    def _post(self, payload: dict) -> tuple[int, dict, str]:
        req = urllib.request.Request(self.url, data=json.dumps(payload).encode(), headers=self.headers, method='POST')
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                text = r.read().decode()
                status = r.status
        except urllib.error.HTTPError as e:
            text, status = e.read().decode(errors='replace'), e.code
        try:
            body = json.loads(text)
        except ValueError:
            body = {}
        return status, body, text

    def run(self, sql: str, params: Sequence = ()) -> list[dict]:
        """Rows of the (first) statement's result."""
        payload: dict = {'sql': sql}
        if params:
            payload['params'] = list(params)
        error = ''
        for attempt in range(self.attempts):
            try:
                status, body, text = self._post(payload)
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                error = str(e)
            else:
                if 200 <= status < 300 and body.get('success'):
                    return body['result'][0].get('results') or []
                error = f"HTTP {status}: {body.get('errors') or text[:200]}"
                if status < 500:
                    break            # a bad statement will not succeed on retry
            if attempt + 1 < self.attempts:
                time.sleep(self.pause * (attempt + 1))
        raise RuntimeError(f'D1 {sql.split()[0] if sql.split() else "query"} failed: {error}')
