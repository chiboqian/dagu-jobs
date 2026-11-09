"""Email through Gmail SMTP (GMAIL_USER, GMAIL_PASSWORD = an app password), to ALERT_EMAIL by default."""
from __future__ import annotations

import shutil
import smtplib
import ssl
import subprocess
from email.message import EmailMessage
from pathlib import Path

from .config import require, setting


def message(subject: str, sender: str, to: str, text: str | None = None, html: str | None = None) -> EmailMessage:
    """Plain text, HTML, or both (multipart/alternative, text first)."""
    if not text and not html:
        raise ValueError('an email needs text or html')
    msg = EmailMessage()
    msg['Subject'], msg['From'], msg['To'] = subject, sender, to
    if text:
        msg.set_content(text)
        if html:
            msg.add_alternative(html, subtype='html')
    else:
        msg.set_content(html, subtype='html')
    return msg


def send(subject: str, text: str | None = None, html: str | None = None, to: str | None = None,
         env_file: Path | str | None = None, local_fallback: bool = False, timeout: float = 60) -> str:
    """Send one email; returns 'gmail' or 'local'. Raises if it can't be sent. With local_fallback,
    a Gmail failure falls back to the host's `mail` command (text only), as Trading's
    shared-utils/send_email.py does."""
    to = to or setting('ALERT_EMAIL', env_file)
    if not to:
        raise RuntimeError('no recipient: pass to= or set ALERT_EMAIL')
    try:
        cred = require(('GMAIL_USER', 'GMAIL_PASSWORD'), env_file)
        msg = message(subject, cred['GMAIL_USER'], to, text, html)
        with smtplib.SMTP('smtp.gmail.com', 587, timeout=timeout) as server:
            server.starttls(context=ssl.create_default_context())
            server.login(cred['GMAIL_USER'], cred['GMAIL_PASSWORD'])
            server.send_message(msg)
        return 'gmail'
    except Exception:
        if not local_fallback or not shutil.which('mail'):
            raise
    body = text or html or ''
    res = subprocess.run(['mail', '-s', subject, to], input=body, text=True)
    if res.returncode != 0:
        raise RuntimeError(f'local mail failed (exit {res.returncode})')
    return 'local'


def check_login(env_file: Path | str | None = None, timeout: float = 60) -> None:
    """Log in to Gmail and quit, sending nothing (a credentials check)."""
    cred = require(('GMAIL_USER', 'GMAIL_PASSWORD'), env_file)
    with smtplib.SMTP('smtp.gmail.com', 587, timeout=timeout) as server:
        server.starttls(context=ssl.create_default_context())
        server.login(cred['GMAIL_USER'], cred['GMAIL_PASSWORD'])
