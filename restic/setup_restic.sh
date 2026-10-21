#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTIC_DIR="${RESTIC_DIR:-$HOME/restic}"
RESTIC_BIN="${RESTIC_DIR}/restic"
ENV_FILE="${RESTIC_DIR}/.env"
BACKUP_SCRIPT="${RESTIC_DIR}/backup.sh"

RESTIC_SERVER="${RESTIC_SERVER:-}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
BACKUP_PATHS="${BACKUP_PATHS:-$HOME}"

usage() {
  cat <<EOF
Usage: $0 [options] <RESTIC_SERVER>

Download the restic binary into ~/restic, save the master password in ~/restic/.env,
initialize the backup repository at the REST server under <hostname>-<username>,
and create ~/restic/backup.sh.

Options:
  -s, --server URL        Restic REST server URL or host:port (e.g. http://backup.example.com:8000)
  -p, --password PASS     Restic master password (prompted interactively if omitted)
  -b, --backup-paths DIR  Space-separated default paths to back up (default: \$HOME)
  -h, --help              Show this help message

Examples:
  $0 http://backup.luna-strategy.com:8000
  $0 backup.luna-strategy.com:8000
EOF
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--server)
      RESTIC_SERVER="$2"
      shift 2
      ;;
    -p|--password)
      RESTIC_PASSWORD="$2"
      shift 2
      ;;
    -b|--backup-paths)
      BACKUP_PATHS="$2"
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

if [[ ${#POSITIONAL[@]} -ge 1 && -z "$RESTIC_SERVER" ]]; then
  RESTIC_SERVER="${POSITIONAL[0]}"
fi

if [[ -z "$RESTIC_SERVER" ]]; then
  usage >&2
  exit 1
fi

# Normalize REST server URL
SERVER_CLEAN="${RESTIC_SERVER#rest:}"
SERVER_CLEAN="${SERVER_CLEAN%/}"
if [[ "$SERVER_CLEAN" != http://* && "$SERVER_CLEAN" != https://* ]]; then
  SERVER_CLEAN="http://${SERVER_CLEAN}"
fi

TARGET_NAME="$(hostname -s)-$(whoami)"
RESTIC_REPOSITORY="rest:${SERVER_CLEAN}/${TARGET_NAME}/"

mkdir -p "$RESTIC_DIR"
chmod 700 "$RESTIC_DIR"

# 1. Detect OS/architecture & download restic binary to ~/restic/restic
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l|armv6l) ARCH="arm" ;;
  i386|i686) ARCH="386" ;;
  ppc64le) ARCH="ppc64le" ;;
  s390x) ARCH="s390x" ;;
  riscv64) ARCH="riscv64" ;;
  *)
    echo "Unsupported architecture: $ARCH_RAW" >&2
    exit 1
    ;;
esac

TAG="$(curl -fsSL https://api.github.com/repos/restic/restic/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)"
TAG="${TAG:-v0.19.1}"
VERSION="${TAG#v}"
DOWNLOAD_URL="https://github.com/restic/restic/releases/download/${TAG}/restic_${VERSION}_${OS}_${ARCH}.bz2"

echo "[1/4] Downloading restic ${TAG} (${OS}/${ARCH}) to ${RESTIC_BIN}..."
python3 - "$DOWNLOAD_URL" "$RESTIC_BIN" <<'PYEOF'
import bz2
import os
import sys
import urllib.request

url, dest = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=60) as resp:
    compressed = resp.read()
data = bz2.decompress(compressed)
tmp_dest = dest + ".tmp"
with open(tmp_dest, "wb") as f:
    f.write(data)
os.chmod(tmp_dest, 0o755)
os.replace(tmp_dest, dest)
PYEOF

echo "Installed: $("$RESTIC_BIN" version)"

# 2. Prompt for master password if not provided and write ~/restic/.env
if [[ -z "$RESTIC_PASSWORD" ]]; then
  read -r -s -p "Enter Restic Master Password: " RESTIC_PASSWORD
  echo ""
  if [[ -z "$RESTIC_PASSWORD" ]]; then
    echo "Error: Master password cannot be empty." >&2
    exit 1
  fi
fi

echo "[2/4] Saving configuration and password to ${ENV_FILE}..."
umask 077
python3 - "$ENV_FILE" "$RESTIC_REPOSITORY" "$RESTIC_PASSWORD" "$RESTIC_BIN" "$BACKUP_PATHS" <<'PYEOF'
import os
import shlex
import sys

env_file, repo, password, restic_bin, backup_paths = sys.argv[1:6]
lines = [
    f"RESTIC_REPOSITORY={shlex.quote(repo)}",
    f"RESTIC_PASSWORD={shlex.quote(password)}",
    f"RESTIC_BIN={shlex.quote(restic_bin)}",
    f"BACKUP_PATHS={shlex.quote(backup_paths)}",
]
with open(env_file, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
os.chmod(env_file, 0o600)
PYEOF

# 3. Create ~/restic/backup.sh
echo "[3/4] Creating backup runner script at ${BACKUP_SCRIPT}..."
if [[ "$(realpath "$SCRIPT_DIR/backup.sh")" != "$(realpath -m "$BACKUP_SCRIPT")" ]]; then
  cp "$SCRIPT_DIR/backup.sh" "$BACKUP_SCRIPT"
fi
chmod +x "$BACKUP_SCRIPT"

# 4. Initialize backup target at the REST server
echo "[4/4] Initializing restic repository at ${RESTIC_REPOSITORY}..."
export RESTIC_REPOSITORY RESTIC_PASSWORD
if "$RESTIC_BIN" cat config >/dev/null 2>&1; then
  echo "Repository already initialized at ${RESTIC_REPOSITORY}."
else
  "$RESTIC_BIN" init
fi

echo ""
echo "Restic setup complete!"
echo "  Binary:      ${RESTIC_BIN}"
echo "  Env File:    ${ENV_FILE} (mode 600)"
echo "  Repository:  ${RESTIC_REPOSITORY}"
echo "  Run Backup:  ${BACKUP_SCRIPT}"
