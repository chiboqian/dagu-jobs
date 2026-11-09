#!/usr/bin/env python3
"""
Read and update the jobs (DAGs) on the Dagu server that schedules every host's jobs.

The server is DAGU_SERVER (default http://jobs.luna-strategy.com:8080), API v1, authenticated
with DAGU_API_KEY from the environment or ~/.config/dagu-jobs/api.env (DAGU_ENV_FILE overrides
the path; a full-access key: never print it). Each job runs on the worker its worker_selector names (host + user); its labels must include
that host and user (`host`, `user`), and may add others. Schedules are New York time.

Reading is safe. Changing a job is two steps: `put` without --yes prints the diff against the
live spec and changes nothing; with --yes it saves the live spec to
backups/<job>_<time>.yaml (next to this script), writes the new one and reads it back. A backup is
restored the same way (`put JOB <backup file> --yes`). Output masks digit runs of 7+ (account
numbers) and the key, so edit a copy from `export` (the raw specs), never `show` output: put
refuses a spec with the masks in it.

Usage:
    ~/dagu-jobs/.venv/bin/python ~/dagu-jobs/dagu_jobs.py list [--host n8n-prod-01] [--user production]
    ... show sync_trades_r2
    ... runs prod-health-check [-n 10]
    ... log prod-health-check [--run RUN_ID]      # latest run by default
    ... export --host n8n-prod-01 --out /tmp/specs  # one YAML per job
    ... put sync_alpaca_fees new.yaml [--create] [--yes]
"""

import argparse
import difflib
import json
import logging
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import yaml
from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parent
BACKUPS = ROOT / 'backups'
ENV_FILE = Path(os.getenv('DAGU_ENV_FILE', Path.home() / '.config' / 'dagu-jobs' / 'api.env'))
DEFAULT_SERVER = 'http://jobs.luna-strategy.com:8080'

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger('DaguJobs')


class Dagu:
    def __init__(self, server: str, key: str):
        self.base = server.rstrip('/') + '/api/v1'
        self.key = key

    def api(self, method: str, path: str, payload: Optional[dict] = None) -> Tuple[int, object]:
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method, headers={
            'Authorization': f'Bearer {self.key}', 'Accept': 'application/json', 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read()
                return r.status, json.loads(body) if body.strip() else {}
        except urllib.error.HTTPError as e:
            return e.code, e.read()[:500].decode(errors='replace')

    def get(self, path: str) -> dict:
        st, body = self.api('GET', path)
        if st != 200 or not isinstance(body, dict):
            raise RuntimeError(f'GET {path}: HTTP {st}: {body}')
        return body

    def dags(self) -> List[dict]:
        out, page = [], 1
        while True:
            d = self.get(f'/dags?perPage=100&page={page}')
            out += d.get('dags') or []
            if not (d.get('pagination') or {}).get('hasNextPage'):
                return out
            page += 1

    def dag(self, name: str) -> Optional[dict]:
        st, body = self.api('GET', '/dags/' + urllib.parse.quote(name))
        return body if st == 200 and isinstance(body, dict) else None

    def runs(self, name: str) -> List[dict]:
        runs = self.get(f'/dags/{urllib.parse.quote(name)}/dag-runs').get('dagRuns') or []
        return sorted(runs, key=lambda r: r.get('startedAt') or r.get('queuedAt') or '', reverse=True)


def mask(text: str, key: str = '') -> str:
    text = re.sub(r'\d{7,}', '<m>', str(text))
    return text.replace(key, '<key>') if key else text


def label(labels: List[str], k: str) -> str:
    return next((x.split('=', 1)[1] for x in labels or [] if x.startswith(k + '=')), '-')


def check_spec(spec: str) -> List[str]:
    """Problems with a spec: unparsable YAML, no steps, masked text from `show`, `host` / `user`
    labels missing or different from the worker_selector's. Other labels are allowed."""
    if '<m>' in spec or '<key>' in spec:
        return ["masked text (<m>/<key>) from `show`: edit an `export` copy instead"]
    try:
        y = yaml.safe_load(spec)
    except yaml.YAMLError as e:
        return [f'YAML does not parse: {e}']
    if not isinstance(y, dict):
        return ['spec is not a mapping']
    problems = []
    if not y.get('steps'):
        problems.append('no steps')
    ws = y.get('worker_selector') or {}
    if not ws.get('host') or not ws.get('user'):
        problems.append('worker_selector lacks host or user: the job could run on any worker')
    labels = y.get('labels') or {}
    if isinstance(labels, str):                     # Dagu also takes "k=v,k2=v2" ...
        labels = labels.split(',')
    if isinstance(labels, list):                    # ... and ["k=v", "bare"]
        labels = dict((str(x).strip().split('=', 1) + [''])[:2] for x in labels)
    for k in ('host', 'user'):
        if str(labels.get(k, '')) != str(ws.get(k, '')):
            problems.append(f"label {k}={labels.get(k)!r} is not the worker_selector's {k} {ws.get(k)!r}")
    return problems


def cmd_list(d: Dagu, a) -> int:
    rows = []
    for x in d.dags():
        g, run = x['dag'], x.get('latestDAGRun') or {}
        host, user = label(g.get('labels'), 'host'), label(g.get('labels'), 'user')
        if (a.host and host != a.host) or (a.user and user != a.user):
            continue
        rows.append((host, user, x['fileName'], ', '.join(s['expression'] for s in g.get('schedule') or []) or '-',
                     'SUSPENDED' if x.get('suspended') else '', run.get('statusLabel', '-'),
                     (run.get('startedAt') or '-')[:16], (x.get('nextRun') or g.get('nextRun') or '-')[:16]))
    head = ('host', 'user', 'job', 'schedule', 'state', 'last', 'last start', 'next run')
    widths = [max(len(str(r[i])) for r in rows + [head]) for i in range(len(head))]
    for r in [head] + sorted(rows):
        print(mask('  '.join(str(c).ljust(w) for c, w in zip(r, widths)).rstrip(), d.key))
    return 0


def cmd_show(d: Dagu, a) -> int:
    x = d.dag(a.job)
    if not x:
        logger.error(f'No job {a.job}')
        return 1
    spec = mask(x.get('spec') or '', d.key)
    sys.stdout.write(spec if spec.endswith('\n') else spec + '\n')
    return 0


def cmd_runs(d: Dagu, a) -> int:
    for r in d.runs(a.job)[:a.n]:
        print(mask(f"{(r.get('startedAt') or r.get('queuedAt') or '-')[:19]}  {r.get('statusLabel', '-'):<10} "
                   f"{r.get('triggerType') or 'manual':<10} {r.get('workerId') or '-'}  {r.get('dagRunId')}", d.key))
    return 0


def cmd_log(d: Dagu, a) -> int:
    """A run's scheduler log and each step's status, exit and stderr tail. The API does not
    serve a step's stdout: on the worker it is the stdout path printed here."""
    run_id = a.run or (d.runs(a.job) or [{}])[0].get('dagRunId')
    if not run_id:
        logger.error(f'No runs for {a.job}')
        return 1
    q = urllib.parse.quote(a.job)
    st, log = d.api('GET', f'/dag-runs/{q}/{run_id}/log')
    if st == 200 and isinstance(log, dict):
        print(mask(log.get('content') or '', d.key).rstrip())
    det = d.get(f'/dag-runs/{q}/{run_id}').get('dagRunDetails') or {}
    for n in det.get('nodes') or []:
        print(mask(f"step {n.get('step', {}).get('name')}: {n.get('statusLabel')}, error {n.get('error') or '-'}", d.key))
        for k in ('stdout', 'stderr'):
            if n.get(k):
                print(f'  {k}: {mask(n[k], d.key)}')
    return 0


def cmd_export(d: Dagu, a) -> int:
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    n = 0
    for x in d.dags():
        g = x['dag']
        if (a.host and label(g.get('labels'), 'host') != a.host) or (a.user and label(g.get('labels'), 'user') != a.user):
            continue
        spec = (d.dag(x['fileName']) or {}).get('spec') or ''
        (out / f"{x['fileName']}.yaml").write_text(spec)
        n += 1
    logger.info(f'Saved {n} spec(s) to {out}')
    return 0


def cmd_put(d: Dagu, a) -> int:
    new = Path(a.file).read_text()
    problems = check_spec(new)
    for p in problems:
        logger.warning(f'{a.file}: {p}')
    if any(p.startswith(('YAML', 'spec is not', 'no steps', 'masked')) for p in problems):
        logger.error('Not sending a spec that cannot run')
        return 1
    cur = d.dag(a.job)
    if cur is None and not a.create:
        logger.error(f'No job {a.job} on the server (use --create for a new one)')
        return 1
    if cur is not None and a.create:
        logger.error(f'{a.job} already exists: drop --create to replace its spec')
        return 1
    old = (cur or {}).get('spec') or ''
    if old == new:
        logger.info(f'{a.job}: the server already has this spec')
        return 0
    diff = difflib.unified_diff(old.splitlines(keepends=True), new.splitlines(keepends=True),
                                f'{a.job} (server)', f'{a.job} ({a.file})')
    sys.stdout.write(mask(''.join(diff), d.key))
    sys.stdout.flush()
    if not a.yes:
        logger.info('Dry run: nothing changed. Re-run with --yes to apply.')
        return 0

    if cur is not None:
        BACKUPS.mkdir(parents=True, exist_ok=True)
        backup = BACKUPS / f"{a.job}_{time.strftime('%Y%m%d-%H%M%S')}.yaml"
        backup.write_text(old)
        logger.info(f'Saved the live spec to {backup}')
    else:
        st, res = d.api('POST', '/dags', {'name': a.job, 'spec': new})
        if st not in (200, 201) or (isinstance(res, dict) and res.get('errors')):
            logger.error(f'Create {a.job}: HTTP {st}: {mask(res, d.key)}')
            return 1
    st, res = d.api('PUT', f'/dags/{urllib.parse.quote(a.job)}/spec', {'spec': new})
    if st != 200 or (isinstance(res, dict) and res.get('errors')):
        logger.error(f'Update {a.job}: HTTP {st}: {mask(res, d.key)}')
        return 1
    after = d.dag(a.job) or {}
    g = after.get('dag') or {}
    same = (after.get('spec') or '') == new
    logger.info(f"{a.job}: {'updated' if cur else 'created'}{'' if same else ', but the read-back spec differs'}; "
                f"schedule {[s['expression'] for s in g.get('schedule') or []]}, next run {g.get('nextRun')}, "
                f"errors {after.get('errors')}")
    return 0 if same and not after.get('errors') else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__)
    ap.add_argument('--server', default=os.getenv('DAGU_SERVER', DEFAULT_SERVER))
    ap.add_argument('--env-file', default=str(ENV_FILE), help='where DAGU_API_KEY is, if not in the environment')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('list', help='every job: host, user, schedule, last run, next run')
    p.add_argument('--host'); p.add_argument('--user')
    p = sub.add_parser('show', help="a job's spec YAML")
    p.add_argument('job')
    p = sub.add_parser('runs', help="a job's recent runs")
    p.add_argument('job'); p.add_argument('-n', type=int, default=10)
    p = sub.add_parser('log', help="a run's log and step errors (latest run by default)")
    p.add_argument('job'); p.add_argument('--run')
    p = sub.add_parser('export', help='save specs, one YAML per job')
    p.add_argument('--out', required=True); p.add_argument('--host'); p.add_argument('--user')
    p = sub.add_parser('put', help="replace (or --create) a job's spec: a diff only, unless --yes")
    p.add_argument('job'); p.add_argument('file')
    p.add_argument('--create', action='store_true', help='the job is new')
    p.add_argument('--yes', action='store_true', help='apply (after backing up the live spec)')
    a = ap.parse_args()

    key = os.getenv('DAGU_API_KEY') or dotenv_values(a.env_file).get('DAGU_API_KEY')
    if not key:
        logger.error(f'DAGU_API_KEY is not set (environment or {a.env_file})')
        return 1
    d = Dagu(a.server, key)
    cmds: Dict[str, object] = {'list': cmd_list, 'show': cmd_show, 'runs': cmd_runs, 'log': cmd_log,
                               'export': cmd_export, 'put': cmd_put}
    try:
        return cmds[a.cmd](d, a)
    except (RuntimeError, urllib.error.URLError) as e:
        logger.error(mask(e, key))
        return 1


if __name__ == '__main__':
    sys.exit(main())
