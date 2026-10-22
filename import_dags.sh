#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAGS_DIR="${DAGS_DIR:-${SCRIPT_DIR}/dags}"
DAG_FILE="${DAG_FILE:-}"
DAGU_SERVER="${DAGU_SERVER:-http://jobs.luna-strategy.com:8080}"
DAGU_USER="${DAGU_USER:-}"
DAGU_PASSWORD="${DAGU_PASSWORD:-}"

usage() {
  cat <<EOF
Usage: $0 [options] [USERNAME] [PASSWORD]

Authenticate against the Dagu server with username/password and import all
DAG YAML files from DAGS_DIR (or a single file with -f), creating new DAGs or
updating existing ones.

Options:
  -u, --user USER         Dagu username (or set DAGU_USER)
  -p, --password PASS     Dagu password (or set DAGU_PASSWORD)
  -s, --server URL        Dagu server URL (default: ${DAGU_SERVER})
  -d, --dags-dir DIR      Directory containing .yaml files (default: ${DAGS_DIR})
  -f, --file FILE         Import only a specific .yaml file
  -h, --help              Show this help message

Examples:
  $0 admin mypassword
  $0 -u admin -p mypassword
  $0   # prompts interactively for username and password
EOF
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)
      DAGU_USER="$2"
      shift 2
      ;;
    -p|--password)
      DAGU_PASSWORD="$2"
      shift 2
      ;;
    -s|--server)
      DAGU_SERVER="$2"
      shift 2
      ;;
    -d|--dags-dir)
      DAGS_DIR="$2"
      shift 2
      ;;
    -f|--file)
      DAG_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL[@]} -ge 1 && -z "$DAGU_USER" ]]; then
  DAGU_USER="${POSITIONAL[0]}"
fi
if [[ ${#POSITIONAL[@]} -ge 2 && -z "$DAGU_PASSWORD" ]]; then
  DAGU_PASSWORD="${POSITIONAL[1]}"
fi

if [[ -z "$DAGU_USER" ]]; then
  read -r -p "Dagu Username: " DAGU_USER
fi
if [[ -z "$DAGU_PASSWORD" ]]; then
  read -r -s -p "Dagu Password: " DAGU_PASSWORD
  echo ""
fi

export DAGU_SERVER DAGU_USER DAGU_PASSWORD DAGS_DIR DAG_FILE

python3 - <<'PYEOF'
import glob
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

server = os.environ["DAGU_SERVER"].rstrip("/")
if not server.endswith("/api/v1"):
    api_url = f"{server}/api/v1"
else:
    api_url = server

username = os.environ["DAGU_USER"]
password = os.environ["DAGU_PASSWORD"]
dags_dir = os.environ["DAGS_DIR"]
dag_file = os.environ.get("DAG_FILE", "").strip()


def api_request(method: str, path: str, payload=None, token=None):
    url = f"{api_url}{path}"
    headers = {"Accept": "application/json"}
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode("utf-8")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            err_body = json.loads(raw) if raw else {}
        except Exception:
            err_body = {"message": raw}
        return e.code, err_body


if dag_file:
    if not os.path.isfile(dag_file):
        print(f"DAG file not found: {dag_file}", file=sys.stderr)
        sys.exit(1)
    yaml_files = [dag_file]
    source_desc = dag_file
else:
    yaml_files = sorted(glob.glob(os.path.join(dags_dir, "*.yaml")))
    if not yaml_files:
        print(f"No .yaml files found in {dags_dir}", file=sys.stderr)
        sys.exit(1)
    source_desc = dags_dir

print(f"Authenticating as '{username}' against {api_url}...")
status, body = api_request("POST", "/auth/login", {"username": username, "password": password})
if status != 200 or "token" not in body:
    msg = body.get("message") or body
    print(f"Login failed (HTTP {status}): {msg}", file=sys.stderr)
    sys.exit(1)

token = body["token"]
print(f"Authenticated successfully. Importing {len(yaml_files)} DAG(s) from {source_desc}...\n")

created = 0
updated = 0
failed = 0

for path in yaml_files:
    name = os.path.splitext(os.path.basename(path))[0]
    with open(path, "r", encoding="utf-8") as f:
        spec = f.read()

    # Try creating with spec first
    st, res = api_request("POST", "/dags", {"name": name, "spec": spec}, token=token)
    if st in (200, 201):
        # Ensure spec is persisted even if POST /dags only initializes an empty template on some versions
        st_put, res_put = api_request(
            "PUT", f"/dags/{urllib.parse.quote(name)}/spec", {"spec": spec}, token=token
        )
        if st_put == 200 and not res_put.get("errors"):
            print(f"  [CREATED] {name}")
            created += 1
        else:
            print(f"  [CREATED] {name} (spec status: {st_put})")
            created += 1
    elif st == 409 or "already exists" in str(res).lower():
        st_put, res_put = api_request(
            "PUT", f"/dags/{urllib.parse.quote(name)}/spec", {"spec": spec}, token=token
        )
        if st_put == 200 and not res_put.get("errors"):
            print(f"  [UPDATED] {name}")
            updated += 1
        else:
            print(f"  [FAILED]  {name} (HTTP {st_put}): {res_put}", file=sys.stderr)
            failed += 1
    else:
        print(f"  [FAILED]  {name} (HTTP {st}): {res}", file=sys.stderr)
        failed += 1

print(f"\nDone! Created: {created}, Updated: {updated}, Failed: {failed}")
if failed > 0:
    sys.exit(1)
PYEOF
