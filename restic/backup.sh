#!/usr/bin/env bash
set -euo pipefail

RESTIC_DIR="${RESTIC_DIR:-$HOME/restic}"
ENV_FILE="${ENV_FILE:-${RESTIC_DIR}/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: Environment file not found at ${ENV_FILE}. Run setup_restic.sh first." >&2
  exit 1
fi

# Load RESTIC_REPOSITORY, RESTIC_PASSWORD, RESTIC_BIN, BACKUP_PATHS from ~/restic/.env
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

RESTIC_BIN="${RESTIC_BIN:-${RESTIC_DIR}/restic}"
if [[ ! -x "$RESTIC_BIN" ]]; then
  echo "Error: restic binary not found or not executable at ${RESTIC_BIN}." >&2
  exit 1
fi

if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD:-}" ]]; then
  echo "Error: RESTIC_REPOSITORY and RESTIC_PASSWORD must be set in ${ENV_FILE}." >&2
  exit 1
fi

HOST_USER="$(hostname -s)-$(whoami)"

if [[ $# -gt 0 ]]; then
  echo "Running restic backup to ${RESTIC_REPOSITORY} with args: $*"
  exec "$RESTIC_BIN" backup --tag "$HOST_USER" "$@"
else
  # Default to BACKUP_PATHS from .env (or $HOME if unset)
  read -r -a TARGETS <<< "${BACKUP_PATHS:-$HOME}"
  echo "Running restic backup of [${TARGETS[*]}] to ${RESTIC_REPOSITORY}..."
  exec "$RESTIC_BIN" backup \
    --tag "$HOST_USER" \
    --exclude="${HOME}/.cache" \
    "${TARGETS[@]}"
fi
