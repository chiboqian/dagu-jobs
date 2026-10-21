#!/usr/bin/env bash
set -euo pipefail

COORDINATOR_INPUT="${1:-${COORDINATOR_HOST:-}}"
COORDINATOR_PORT="${2:-${COORDINATOR_PORT:-50055}}"

if [[ -z "$COORDINATOR_INPUT" ]]; then
  echo "Usage: $0 <COORDINATOR_HOST> [COORDINATOR_PORT]"
  echo "Example: $0 jobs.luna-strategy.com"
  exit 1
fi

if [[ "$COORDINATOR_INPUT" == *:* ]]; then
  COORDINATOR_ADDR="$COORDINATOR_INPUT"
else
  COORDINATOR_ADDR="${COORDINATOR_INPUT}:${COORDINATOR_PORT}"
fi

JOBS_DIR="${JOBS_DIR:-$HOME/jobs}"
BIN_DIR="${BIN_DIR:-${JOBS_DIR}/bin}"
DAGU_BIN="${BIN_DIR}/dagu"
RUN_SCRIPT="${JOBS_DIR}/run_worker.sh"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_NAME="dagu-worker.service"
SERVICE_FILE="${SYSTEMD_USER_DIR}/${SERVICE_NAME}"

mkdir -p "$JOBS_DIR" "$BIN_DIR" "$SYSTEMD_USER_DIR"

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

echo "[1/3] Downloading Dagu ${TAG} (${OS}/${ARCH}) to ${DAGU_BIN}..."
curl -fsSL "$DOWNLOAD_URL" | tar -xz -C "$BIN_DIR" dagu
chmod +x "$DAGU_BIN"
echo "Installed Dagu version: $("$DAGU_BIN" version)"

# 2. Create ~/jobs/run_worker.sh
echo "[2/3] Creating worker runner script at ${RUN_SCRIPT}..."
cat > "$RUN_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
cd "\$SCRIPT_DIR"

COORDINATOR_ADDR="\${COORDINATOR_ADDR:-${COORDINATOR_ADDR}}"
WORKER_ID="\${WORKER_ID:-\$(hostname -s)-\$(whoami)}"
WORKER_LABELS="\${WORKER_LABELS:-host=\$(hostname -s),user=\$(whoami)}"
DAGU_BIN="\${DAGU_BIN:-${DAGU_BIN}}"

echo "Starting Dagu worker '\${WORKER_ID}' (labels: \${WORKER_LABELS}) connecting to \${COORDINATOR_ADDR}..."

export DAGU_AUTH_MODE="\${DAGU_AUTH_MODE:-none}"
exec "\$DAGU_BIN" worker \\
  --worker.id="\${WORKER_ID}" \\
  --worker.labels="\${WORKER_LABELS}" \\
  --worker.coordinators="\${COORDINATOR_ADDR}" \\
  "\$@"
EOF
chmod +x "$RUN_SCRIPT"

# 3. Create and enable user-level systemd service
echo "[3/3] Creating user-level systemd service at ${SERVICE_FILE}..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Dagu Worker ($(hostname -s)-$(whoami))
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${JOBS_DIR}
ExecStart=${RUN_SCRIPT}
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
echo "  Worker ID:        $(hostname -s)-$(whoami)"
echo "  Coordinator:      ${COORDINATOR_ADDR}"
echo "  Runner Script:    ${RUN_SCRIPT}"
echo "  Systemd Service:  ${SERVICE_FILE}"
echo ""
systemctl --user --no-pager status "$SERVICE_NAME" || true
