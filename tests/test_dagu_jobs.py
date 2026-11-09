#!/usr/bin/env python3
"""Unit tests for dagu_jobs.py. No network: the Dagu API is an in-memory fake.

Run: .venv/bin/python tests/test_dagu_jobs.py -v
"""

import argparse
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import dagu_jobs as dj  # noqa: E402

KEY = "secret-key-123"
SPEC = '''description: "test"
schedule: "45 20 * * 1-5"
labels:
  host: "n8n-prod-01"
  user: "production"
worker_selector:
  host: "n8n-prod-01"
  user: "production"
steps:
  - name: s
    run: "python util/x.py --accounts U12345678"
'''


class FakeDagu(dj.Dagu):
    def __init__(self, specs):
        super().__init__("http://dagu.test", KEY)
        self.specs = dict(specs)
        self.calls = []

    def api(self, method, path, payload=None):
        self.calls.append((method, path))
        name = path.split("/")[2] if path.startswith("/dags/") else None
        if method == "GET" and name and path.count("/") == 2:
            if name not in self.specs:
                return 404, "not found"
            return 200, {"spec": self.specs[name], "dag": {"schedule": [{"expression": "45 20 * * 1-5"}]}, "errors": []}
        if method == "POST" and path == "/dags":
            self.specs[payload["name"]] = ""
            return 201, {}
        if method == "PUT" and path.endswith("/spec"):
            self.specs[name] = payload["spec"]
            return 200, {}
        return 404, "no route"


def put_args(job, file, create=False, yes=False):
    return argparse.Namespace(job=job, file=str(file), create=create, yes=yes)


class Put(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.backups = mock.patch.object(dj, "BACKUPS", self.dir / "backups")
        self.backups.start()

    def tearDown(self):
        self.backups.stop()
        self.tmp.cleanup()

    def spec_file(self, text, name="new.yaml"):
        f = self.dir / name
        f.write_text(text)
        return f

    def test_dry_run_changes_nothing(self):
        d = FakeDagu({"job": SPEC})
        self.assertEqual(dj.cmd_put(d, put_args("job", self.spec_file(SPEC.replace("45 20", "46 20")))), 0)
        self.assertEqual(d.specs["job"], SPEC)
        self.assertFalse([c for c in d.calls if c[0] != "GET"])

    def test_yes_backs_up_then_writes(self):
        d = FakeDagu({"job": SPEC})
        new = SPEC.replace("45 20", "46 20")
        self.assertEqual(dj.cmd_put(d, put_args("job", self.spec_file(new), yes=True)), 0)
        self.assertEqual(d.specs["job"], new)
        backups = list((self.dir / "backups").glob("job_*.yaml"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), SPEC)

    def test_create_needs_flag_and_new_name(self):
        d = FakeDagu({"job": SPEC})
        f = self.spec_file(SPEC)
        self.assertEqual(dj.cmd_put(d, put_args("other", f, yes=True)), 1)
        self.assertEqual(dj.cmd_put(d, put_args("job", self.spec_file(SPEC + "#\n", "changed.yaml"), create=True, yes=True)), 1)
        self.assertEqual(dj.cmd_put(d, put_args("other", f, create=True, yes=True)), 0)
        self.assertEqual(d.specs["other"], SPEC)

    def test_refuses_masked_spec(self):
        d = FakeDagu({"job": SPEC})
        masked = dj.mask(SPEC.replace("45 20", "46 20"), KEY)
        self.assertIn("<m>", masked)
        self.assertEqual(dj.cmd_put(d, put_args("job", self.spec_file(masked), yes=True)), 1)
        self.assertEqual(d.specs["job"], SPEC)

    def test_unchanged_spec_is_a_no_op(self):
        d = FakeDagu({"job": SPEC})
        self.assertEqual(dj.cmd_put(d, put_args("job", self.spec_file(SPEC), yes=True)), 0)
        self.assertFalse([c for c in d.calls if c[0] != "GET"])


class Checks(unittest.TestCase):
    def test_host_and_user_labels_required_others_optional(self):
        self.assertEqual(dj.check_spec(SPEC), [])
        extra = SPEC.replace('  user: "production"\nworker', '  user: "production"\n  type: "x"\n  tag: ""\nworker')
        self.assertEqual(dj.check_spec(extra), [])
        no_user = SPEC.replace('labels:\n  host: "n8n-prod-01"\n  user: "production"\n', 'labels:\n  host: "n8n-prod-01"\n')
        self.assertTrue(any(p.startswith("label user=") for p in dj.check_spec(no_user)))
        wrong_host = SPEC.replace('labels:\n  host: "n8n-prod-01"', 'labels:\n  host: "llm-01"')
        self.assertTrue(any(p.startswith("label host=") for p in dj.check_spec(wrong_host)))
        as_list = SPEC.replace('labels:\n  host: "n8n-prod-01"\n  user: "production"\n',
                               'labels:\n  - host=n8n-prod-01\n  - user=production\n  - tag\n')
        self.assertEqual(dj.check_spec(as_list), [])

    def test_mask(self):
        self.assertEqual(dj.mask(f"U12345678 key {KEY} 2026", KEY), "U<m> key <key> 2026")


if __name__ == "__main__":
    unittest.main()
