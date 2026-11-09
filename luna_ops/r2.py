"""Cloudflare R2 through its S3 API (boto3, installed with the `r2` extra).

A call names its bucket (bucket_name) or a kind: 'logs' = R2_BUCKET_NAME (logs, trades), 'dashboard' =
R2_DASHBOARD_BUCKET (web pages, served under R2_PUBLIC_URL).
"""
from __future__ import annotations

from pathlib import Path

from .config import require, setting

BUCKETS = {'logs': 'R2_BUCKET_NAME', 'dashboard': 'R2_DASHBOARD_BUCKET'}


def client(env_file: Path | str | None = None):
    c = require(('CLOUDFLARE_ACCOUNT_ID', 'R2_ACCESS_KEY_ID', 'R2_SECRET_ACCESS_KEY'), env_file)
    import boto3                                   # the `r2` extra; checked after the credentials
    return boto3.client('s3', endpoint_url=f"https://{c['CLOUDFLARE_ACCOUNT_ID']}.r2.cloudflarestorage.com",
                        aws_access_key_id=c['R2_ACCESS_KEY_ID'],
                        aws_secret_access_key=c['R2_SECRET_ACCESS_KEY'], region_name='auto')


def bucket(kind: str = 'logs', env_file: Path | str | None = None) -> str:
    """The bucket for a kind: 'logs' (R2_BUCKET_NAME) or 'dashboard' (R2_DASHBOARD_BUCKET)."""
    if kind not in BUCKETS:
        raise ValueError(f'unknown bucket kind {kind!r}: use {sorted(BUCKETS)} or pass bucket_name')
    return require((BUCKETS[kind],), env_file)[BUCKETS[kind]]


def _name(bucket_name: str | None, kind: str, env_file) -> str:
    return bucket_name or bucket(kind, env_file)


def upload_file(path: Path | str, key: str, bucket_name: str | None = None, kind: str = 'logs',
                content_type: str | None = None, cache_control: str | None = None,
                env_file: Path | str | None = None, s3=None) -> str:
    """Upload `path` as `key` to `bucket_name` (default: the `kind` bucket); returns 'bucket/key'."""
    extra = {k: v for k, v in (('ContentType', content_type), ('CacheControl', cache_control)) if v}
    b = _name(bucket_name, kind, env_file)
    (s3 or client(env_file)).upload_file(str(path), b, key, ExtraArgs=extra or None)
    return f'{b}/{key}'


def upload_page(path: Path | str, key: str, bucket_name: str | None = None,
                env_file: Path | str | None = None, s3=None) -> str:
    """An HTML page to the dashboard bucket, not cached; returns its URL under R2_PUBLIC_URL
    (or the key when that isn't set)."""
    upload_file(path, key, bucket_name, 'dashboard', 'text/html; charset=utf-8', 'no-cache', env_file, s3)
    base = (setting('R2_PUBLIC_URL', env_file) or '').rstrip('/')
    return f'{base}/{key}' if base else key


def list_keys(prefix: str = '', bucket_name: str | None = None, kind: str = 'logs',
              env_file: Path | str | None = None, s3=None) -> list[str]:
    s3 = s3 or client(env_file)
    b = _name(bucket_name, kind, env_file)
    keys, token = [], None
    while True:
        kw = {'Bucket': b, 'Prefix': prefix}
        if token:
            kw['ContinuationToken'] = token
        page = s3.list_objects_v2(**kw)
        keys += [o['Key'] for o in page.get('Contents', [])]
        if not page.get('IsTruncated'):
            return keys
        token = page.get('NextContinuationToken')


def read_bytes(key: str, bucket_name: str | None = None, kind: str = 'logs',
               env_file: Path | str | None = None, s3=None) -> bytes:
    s3 = s3 or client(env_file)
    return s3.get_object(Bucket=_name(bucket_name, kind, env_file), Key=key)['Body'].read()
