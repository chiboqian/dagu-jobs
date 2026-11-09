#!/usr/bin/env python3
"""Unit tests for luna_ops. No network: SMTP, S3 and the D1 HTTP API are faked.

Run: .venv/bin/python tests/test_luna_ops.py -v
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from luna_ops import config, d1, mail, r2  # noqa: E402

NAMES = ('ALERT_EMAIL', 'GMAIL_USER', 'GMAIL_PASSWORD', 'CLOUDFLARE_ACCOUNT_ID', 'R2_ACCESS_KEY_ID',
         'R2_SECRET_ACCESS_KEY', 'R2_BUCKET_NAME', 'R2_DASHBOARD_BUCKET', 'R2_PUBLIC_URL',
         'CLOUDFLARE_D1_DATABASE_ID', 'CLOUDFLARE_API_TOKEN')


class Base(unittest.TestCase):
    """A clean environment and a temporary ops.env for every test."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ops = Path(self.tmp.name) / 'ops.env'
        env = {k: v for k, v in os.environ.items() if k not in NAMES}
        env['LUNA_OPS_ENV'] = str(self.ops)
        self.env = mock.patch.dict(os.environ, env, clear=True)
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def write(self, path: Path, text: str) -> Path:
        path.write_text(text)
        return path


class Config(Base):
    def test_environment_then_env_file_then_ops_env(self):
        self.write(self.ops, 'A=from_ops\nB=from_ops\nC=from_ops\n')
        f = self.write(Path(self.tmp.name) / 'p.env', 'B=from_file\nC=from_file\n')
        os.environ['C'] = 'from_environ'
        self.assertEqual([config.setting(k, f) for k in 'ABC'], ['from_ops', 'from_file', 'from_environ'])
        self.assertIsNone(config.setting('D', f))

    def test_env_file_syntax(self):
        f = self.write(Path(self.tmp.name) / 'p.env',
                       '# comment\nexport X="quoted value"\nY=\'single\'\nZ=first\nZ=second\nnot a line\n')
        self.assertEqual(config.read_env(f), {'X': 'quoted value', 'Y': 'single', 'Z': 'first'})

    def test_require_names_missing_settings_but_never_values(self):
        os.environ['GMAIL_USER'] = 'secret-user'
        with self.assertRaises(RuntimeError) as e:
            config.require(('GMAIL_USER', 'GMAIL_PASSWORD'))
        self.assertIn('GMAIL_PASSWORD', str(e.exception))
        self.assertNotIn('secret-user', str(e.exception))


class Mail(Base):
    def test_message_parts(self):
        both = mail.message('s', 'a@x', 'b@x', text='plain', html='<b>rich</b>')
        self.assertEqual(both.get_content_type(), 'multipart/alternative')
        self.assertEqual([p.get_content_type() for p in both.iter_parts()], ['text/plain', 'text/html'])
        self.assertEqual(mail.message('s', 'a@x', 'b@x', html='<b>x</b>').get_content_type(), 'text/html')
        with self.assertRaises(ValueError):
            mail.message('s', 'a@x', 'b@x')

    def test_send_through_gmail_to_alert_email(self):
        self.write(self.ops, 'GMAIL_USER=me@x\nGMAIL_PASSWORD=pw\nALERT_EMAIL=alerts@x\n')
        with mock.patch('smtplib.SMTP') as smtp:
            self.assertEqual(mail.send('Subject', text='t', html='<p>h</p>'), 'gmail')
        server = smtp.return_value.__enter__.return_value
        server.login.assert_called_once_with('me@x', 'pw')
        sent = server.send_message.call_args[0][0]
        self.assertEqual((sent['To'], sent['From'], sent['Subject']), ('alerts@x', 'me@x', 'Subject'))

    def test_local_fallback_only_when_asked(self):
        self.write(self.ops, 'GMAIL_USER=me@x\nGMAIL_PASSWORD=pw\nALERT_EMAIL=alerts@x\n')
        with mock.patch('smtplib.SMTP', side_effect=OSError('down')):
            with self.assertRaises(OSError):
                mail.send('s', text='t')
            with mock.patch('shutil.which', return_value='/usr/bin/mail'), \
                    mock.patch('subprocess.run', return_value=mock.Mock(returncode=0)) as run:
                self.assertEqual(mail.send('s', text='t', local_fallback=True), 'local')
        self.assertEqual(run.call_args[0][0], ['mail', '-s', 's', 'alerts@x'])

    def test_no_recipient(self):
        with self.assertRaises(RuntimeError):
            mail.send('s', text='t')


class FakeS3:
    def __init__(self, pages=None):
        self.uploads, self.pages = [], list(pages or [])

    def upload_file(self, path, bucket, key, ExtraArgs=None):
        self.uploads.append((path, bucket, key, ExtraArgs))

    def list_objects_v2(self, **kw):
        return self.pages.pop(0)


class R2(Base):
    def setUp(self):
        super().setUp()
        self.write(self.ops, 'R2_BUCKET_NAME=logs-b\nR2_DASHBOARD_BUCKET=dash-b\nR2_PUBLIC_URL=https://dash.example/\n')

    def test_bucket_kinds(self):
        self.assertEqual((r2.bucket('logs'), r2.bucket('dashboard')), ('logs-b', 'dash-b'))
        with self.assertRaises(ValueError):
            r2.bucket('logs-b')                      # a name is passed as bucket_name, never as a kind

    def test_upload_file_and_page(self):
        s3 = FakeS3()
        self.assertEqual(r2.upload_file('/tmp/a.gz', 'logs/a.gz', s3=s3), 'logs-b/logs/a.gz')
        self.assertEqual(r2.upload_file('/tmp/b', 'b', 'logs', s3=s3), 'logs/b')   # a bucket really named 'logs'
        self.assertEqual(r2.upload_page('/tmp/p.html', 'p.html', s3=s3), 'https://dash.example/p.html')
        self.assertEqual(s3.uploads[0], ('/tmp/a.gz', 'logs-b', 'logs/a.gz', None))
        self.assertEqual(s3.uploads[2], ('/tmp/p.html', 'dash-b', 'p.html',
                                         {'ContentType': 'text/html; charset=utf-8', 'CacheControl': 'no-cache'}))

    def test_list_keys_follows_pages(self):
        s3 = FakeS3([{'Contents': [{'Key': 'a'}], 'IsTruncated': True, 'NextContinuationToken': 't'},
                     {'Contents': [{'Key': 'b'}], 'IsTruncated': False}])
        self.assertEqual(r2.list_keys('x/', s3=s3), ['a', 'b'])

    def test_client_needs_credentials(self):
        with self.assertRaises(RuntimeError):
            r2.client()


class D1(Base):
    def setUp(self):
        super().setUp()
        self.write(self.ops, 'CLOUDFLARE_ACCOUNT_ID=acc\nCLOUDFLARE_D1_DATABASE_ID=db\nCLOUDFLARE_API_TOKEN=tok\n')
        self.db = d1.D1(pause=0)

    def test_url_and_auth(self):
        self.assertTrue(self.db.url.endswith('/accounts/acc/d1/database/db/query'))
        self.assertEqual(self.db.headers['Authorization'], 'Bearer tok')

    def test_retries_server_errors_then_returns_rows(self):
        ok = (200, {'success': True, 'result': [{'results': [{'n': 1}]}]}, '')
        with mock.patch.object(self.db, '_post', side_effect=[(503, {}, 'busy'), OSError('reset'), ok]) as post:
            self.assertEqual(self.db.run('SELECT 1 AS n', [1]), [{'n': 1}])
        self.assertEqual(post.call_count, 3)
        self.assertEqual(post.call_args[0][0], {'sql': 'SELECT 1 AS n', 'params': [1]})

    def test_a_rejected_statement_is_not_retried(self):
        with mock.patch.object(self.db, '_post', return_value=(400, {'errors': ['syntax']}, '')) as post:
            with self.assertRaises(RuntimeError) as e:
                self.db.run('SELEC 1')
        self.assertEqual(post.call_count, 1)
        self.assertIn('syntax', str(e.exception))


if __name__ == '__main__':
    unittest.main()
