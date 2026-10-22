#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORDINATOR_INPUT="${COORDINATOR_HOST:-}"
COORDINATOR_PORT="${COORDINATOR_PORT:-50055}"
UPDATE_SCHEDULE="${UPDATE_SCHEDULE:-0 5 * * 0}"

usage() {
  cat <<EOF
Usage: $0 [options] <COORDINATOR_HOST> [COORDINATOR_PORT]

Options:
  -c, --schedule CRON     Cron schedule for the client auto-update Dagu job (default: "0 5 * * 0", Sunday 5:00 AM)
  -h, --help              Show this help message

Example:
  $0 jobs.luna-strategy.com
EOF
}

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--schedule)
      UPDATE_SCHEDULE="$2"
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

if [[ ${#POSITIONAL[@]} -ge 1 ]]; then
  COORDINATOR_INPUT="${POSITIONAL[0]}"
fi
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then
  COORDINATOR_PORT="${POSITIONAL[1]}"
fi

if [[ -z "$COORDINATOR_INPUT" ]]; then
  usage >&2
  exit 1
fi

if [[ "$COORDINATOR_INPUT" == *:* ]]; then
  COORDINATOR_ADDR="$COORDINATOR_INPUT"
else
  COORDINATOR_ADDR="${COORDINATOR_INPUT}:${COORDINATOR_PORT}"
fi

JOBS_DIR="${JOBS_DIR:-$SCRIPT_DIR}"
BIN_DIR="${BIN_DIR:-${JOBS_DIR}/bin}"
DAGS_DIR="${DAGS_DIR:-${JOBS_DIR}/dags}"
DAGU_BIN="${BIN_DIR}/dagu"
RUN_SCRIPT="${JOBS_DIR}/run_worker.sh"
UPDATE_SCRIPT="${JOBS_DIR}/update_client.sh"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_NAME="dagu-worker.service"
SERVICE_FILE="${SYSTEMD_USER_DIR}/${SERVICE_NAME}"

HOST_SHORT="$(hostname -s)"
CURRENT_USER="$(whoami)"
TARGET_NAME="${HOST_SHORT}-${CURRENT_USER}"
SAFE_PREFIX="$(echo "${HOST_SHORT}_${CURRENT_USER}" | tr -cs 'A-Za-z0-9_' '_' | sed -E 's/^_+|_+$//g' | tr '[:upper:]' '[:lower:]')"
UPDATE_DAG_NAME="${SAFE_PREFIX}_update_client"
UPDATE_DAG_NAME="${UPDATE_DAG_NAME:0:39}"
UPDATE_DAG_NAME="${UPDATE_DAG_NAME%_}"
UPDATE_DAG_FILE="${DAGS_DIR}/${UPDATE_DAG_NAME}.yaml"

mkdir -p "$JOBS_DIR" "$BIN_DIR" "$DAGS_DIR" "$SYSTEMD_USER_DIR"

# 1. Detect OS and architecture & download Dagu CLI
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l) ARCH="armv7" ;;
  armv6l) ARCH="armv6" ;;
  i386|i686) ARCH="386" ;;
  ppc64le) ARCH="ppc64le" ;;
  s390x) ARCH="s390x" ;;
  *)
    echo "Unsupported architecture: $ARCH_RAW" >&2
    exit 1
    ;;
esac

TAG="$(curl -fsSL https://api.github.com/repos/dagucloud/dagu/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)"
TAG="${TAG:-v2.21.0}"
VERSION="${TAG#v}"
DOWNLOAD_URL="https://github.com/dagucloud/dagu/releases/download/${TAG}/dagu_${VERSION}_${OS}_${ARCH}.tar.gz"

echo "[1/5] Downloading Dagu ${TAG} (${OS}/${ARCH}) to ${DAGU_BIN}..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
curl -fsSL "$DOWNLOAD_URL" | tar -xz -C "$TMP_DIR" dagu
chmod +x "$TMP_DIR/dagu"
mv -f "$TMP_DIR/dagu" "$DAGU_BIN"
echo "Installed Dagu version: $("$DAGU_BIN" version)"

# 2. Create ~/jobs/run_worker.sh
echo "[2/5] Creating worker runner script at ${RUN_SCRIPT}..."
cat > "$RUN_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "\$SCRIPT_DIR"

COORDINATOR_ADDR="\${COORDINATOR_ADDR:-${COORDINATOR_ADDR}}"
WORKER_ID="\${WORKER_ID:-\$(hostname -s)-\$(whoami)}"
WORKER_LABELS="\${WORKER_LABELS:-host=\$(hostname -s),user=\$(whoami)}"
WORKER_HEALTH_PORT="\${WORKER_HEALTH_PORT:-0}"
DAGU_BIN="\${DAGU_BIN:-${DAGU_BIN}}"

echo "Starting Dagu worker '\${WORKER_ID}' (labels: \${WORKER_LABELS}) connecting to \${COORDINATOR_ADDR}..."

# Isolate TMPDIR per user so multiple workers on the same host don't collide on /tmp/dagu (0750)
export TMPDIR="\${TMPDIR:-/tmp/dagu-\$(whoami)}"
mkdir -p "\$TMPDIR"
chmod 700 "\$TMPDIR"

export DAGU_AUTH_MODE="\${DAGU_AUTH_MODE:-none}"
exec "\$DAGU_BIN" worker \\
  --worker.id="\${WORKER_ID}" \\
  --worker.labels="\${WORKER_LABELS}" \\
  --worker.health-port="\${WORKER_HEALTH_PORT}" \\
  --worker.coordinators="\${COORDINATOR_ADDR}" \\
  "\$@"
EOF
chmod +x "$RUN_SCRIPT"

# 3. Install ~/jobs/update_client.sh & generate weekly auto-update Dagu job
echo "[3/5] Installing client auto-updater at ${UPDATE_SCRIPT}..."
if [[ "$(realpath "$SCRIPT_DIR/update_client.sh")" != "$(realpath -m "$UPDATE_SCRIPT")" ]]; then
  cp "$SCRIPT_DIR/update_client.sh" "$UPDATE_SCRIPT"
fi
chmod +x "$UPDATE_SCRIPT"

echo "[4/5] Creating Dagu client auto-update job at ${UPDATE_DAG_FILE}..."
cat > "$UPDATE_DAG_FILE" <<EOF
# Client auto-update job (${TARGET_NAME})
description: "Weekly auto-update for Dagu and Restic on ${TARGET_NAME}"
schedule: "${UPDATE_SCHEDULE}"
labels:
  host: "${HOST_SHORT}"
  user: "${CURRENT_USER}"
  type: "maintenance"
worker_selector:
  host: "${HOST_SHORT}"
  user: "${CURRENT_USER}"
shell: "/bin/bash"
working_dir: "${JOBS_DIR}"
steps:
  - name: ${UPDATE_DAG_NAME}
    run: "${UPDATE_SCRIPT}"
EOF

if [[ -d "${SCRIPT_DIR}/dags" && "$(realpath "$DAGS_DIR")" != "$(realpath "${SCRIPT_DIR}/dags")" ]]; then
  cp "$UPDATE_DAG_FILE" "${SCRIPT_DIR}/dags/${UPDATE_DAG_NAME}.yaml"
fi

# 4. Create and enable user-level systemd service
echo "[5/5] Creating user-level systemd service at ${SERVICE_FILE}..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Dagu Worker (${TARGET_NAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${JOBS_DIR}
ExecStart=${RUN_SCRIPT}
KillMode=process
Restart=always
RestartSec=5
TimeoutStopSec=90
Environment="PATH=${BIN_DIR}:${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:/usr/bin:/bin"

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user restart "$SERVICE_NAME"

# Attempt to enable linger so the user service stays running after logout
loginctl enable-linger "$(whoami)" 2>/dev/null || true

echo ""
echo "Setup complete!"
echo "  Worker ID:        ${TARGET_NAME}"
echo "  Coordinator:      ${COORDINATOR_ADDR}"
echo "  Runner Script:    ${RUN_SCRIPT}"
echo "  Updater Script:   ${UPDATE_SCRIPT}"
echo "  Auto-Update DAG:  ${UPDATE_DAG_FILE} (schedule: ${UPDATE_SCHEDULE})"
echo "  Systemd Service:  ${SERVICE_FILE}"
echo ""
systemctl --user --no-pager status "$SERVICE_NAME" || true
