#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="${JOBS_DIR:-$SCRIPT_DIR}"
BIN_DIR="${BIN_DIR:-${JOBS_DIR}/bin}"
DAGU_BIN="${DAGU_BIN:-${BIN_DIR}/dagu}"
RESTIC_DIR="${RESTIC_DIR:-$HOME/restic}"
RESTIC_ENV="${RESTIC_DIR}/.env"

if [[ -f "$RESTIC_ENV" ]]; then
  # shellcheck disable=SC1090
  RESTIC_BIN_FROM_ENV="$(source "$RESTIC_ENV" 2>/dev/null && printf '%s' "${RESTIC_BIN:-}" || true)"
  if [[ -n "$RESTIC_BIN_FROM_ENV" ]]; then
    RESTIC_BIN="${RESTIC_BIN:-$RESTIC_BIN_FROM_ENV}"
  fi
fi
RESTIC_BIN="${RESTIC_BIN:-${RESTIC_DIR}/restic}"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH_RAW="$(uname -m)"

# ---------------------------------------------------------------------------
# 1. Update Restic (if installed)
# ---------------------------------------------------------------------------
if [[ -x "$RESTIC_BIN" ]]; then
  CURRENT_RESTIC_VER="$("$RESTIC_BIN" version 2>/dev/null | awk 'NR==1 {print $2}' | sed 's/^v//' || true)"
  LATEST_RESTIC_TAG="$(curl -fsSL https://api.github.com/repos/restic/restic/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)"
  LATEST_RESTIC_VER="${LATEST_RESTIC_TAG#v}"

  if [[ -z "$LATEST_RESTIC_VER" ]]; then
    echo "[restic] Warning: Could not determine latest restic release from GitHub." >&2
  elif [[ "$CURRENT_RESTIC_VER" == "$LATEST_RESTIC_VER" ]]; then
    echo "[restic] Already up to date (v${CURRENT_RESTIC_VER})."
  else
    echo "[restic] Updating from v${CURRENT_RESTIC_VER:-unknown} to v${LATEST_RESTIC_VER}..."
    if ! "$RESTIC_BIN" self-update; then
      echo "[restic] self-update failed; falling back to direct GitHub release download..."
      case "$ARCH_RAW" in
        x86_64|amd64) RESTIC_ARCH="amd64" ;;
        aarch64|arm64) RESTIC_ARCH="arm64" ;;
        armv7l|armv6l) RESTIC_ARCH="arm" ;;
        i386|i686) RESTIC_ARCH="386" ;;
        ppc64le) RESTIC_ARCH="ppc64le" ;;
        s390x) RESTIC_ARCH="s390x" ;;
        riscv64) RESTIC_ARCH="riscv64" ;;
        *)
          echo "[restic] Unsupported architecture: $ARCH_RAW" >&2
          exit 1
          ;;
      esac
      RESTIC_URL="https://github.com/restic/restic/releases/download/${LATEST_RESTIC_TAG}/restic_${LATEST_RESTIC_VER}_${OS}_${RESTIC_ARCH}.bz2"
      python3 - "$RESTIC_URL" "$RESTIC_BIN" <<'PYEOF'
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
    fi
    echo "[restic] Installed: $("$RESTIC_BIN" version)"
  fi
else
  echo "[restic] Not installed at ${RESTIC_BIN}, skipping."
fi

# ---------------------------------------------------------------------------
# 2. Update Dagu (if installed)
# ---------------------------------------------------------------------------
if [[ -x "$DAGU_BIN" ]]; then
  CURRENT_DAGU_VER="$("$DAGU_BIN" version 2>/dev/null | head -n1 | awk '{print $1}' | sed 's/^v//' || true)"
  LATEST_DAGU_TAG="$(curl -fsSL https://api.github.com/repos/dagucloud/dagu/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)"
  LATEST_DAGU_VER="${LATEST_DAGU_TAG#v}"

  if [[ -z "$LATEST_DAGU_VER" ]]; then
    echo "[dagu] Warning: Could not determine latest Dagu release from GitHub." >&2
  elif [[ "$CURRENT_DAGU_VER" == "$LATEST_DAGU_VER" ]]; then
    echo "[dagu] Already up to date (v${CURRENT_DAGU_VER})."
  else
    echo "[dagu] Updating from v${CURRENT_DAGU_VER:-unknown} to v${LATEST_DAGU_VER}..."
    case "$ARCH_RAW" in
      x86_64|amd64) DAGU_ARCH="amd64" ;;
      aarch64|arm64) DAGU_ARCH="arm64" ;;
      armv7l) DAGU_ARCH="armv7" ;;
      armv6l) DAGU_ARCH="armv6" ;;
      i386|i686) DAGU_ARCH="386" ;;
      ppc64le) DAGU_ARCH="ppc64le" ;;
      s390x) DAGU_ARCH="s390x" ;;
      *)
        echo "[dagu] Unsupported architecture: $ARCH_RAW" >&2
        exit 1
        ;;
    esac

    DAGU_URL="https://github.com/dagucloud/dagu/releases/download/${LATEST_DAGU_TAG}/dagu_${LATEST_DAGU_VER}_${OS}_${DAGU_ARCH}.tar.gz"
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    curl -fsSL "$DAGU_URL" | tar -xz -C "$TMP_DIR" dagu
    chmod +x "$TMP_DIR/dagu"
    mv -f "$TMP_DIR/dagu" "$DAGU_BIN"
    echo "[dagu] Installed version: $("$DAGU_BIN" version)"

    # Delay the service restart by 5 seconds so if this script is running inside a
    # Dagu job, the step finishes and reports success before the worker restarts.
    if systemctl --user is-active --quiet dagu-worker.service 2>/dev/null; then
      echo "[dagu] Scheduling dagu-worker.service restart in 5 seconds..."
      if ! systemd-run --user --on-active=5s systemctl --user restart dagu-worker.service >/dev/null 2>&1; then
        nohup bash -c 'sleep 5 && systemctl --user restart dagu-worker.service' >/dev/null 2>&1 &
      fi
    fi
  fi
else
  echo "[dagu] Binary not found at ${DAGU_BIN}, skipping."
fi
