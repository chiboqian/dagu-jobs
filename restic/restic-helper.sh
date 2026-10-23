#!/usr/bin/env bash
# ==============================================================================
# restic-helper.sh: Automated Restic wrapper that sources .env in its own folder
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: Environment file not found at ${ENV_FILE}." >&2
  exit 1
fi

# Load RESTIC_REPOSITORY, RESTIC_PASSWORD, RESTIC_BIN, etc.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Locate restic binary
RESTIC_BIN="${RESTIC_BIN:-${SCRIPT_DIR}/restic}"
if [[ ! -x "$RESTIC_BIN" ]]; then
  if command -v restic &>/dev/null; then
    RESTIC_BIN="$(command -v restic)"
  else
    echo "Error: restic binary not found at ${RESTIC_BIN} or in PATH." >&2
    exit 1
  fi
fi

if [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD:-}" ]]; then
  echo "Error: RESTIC_REPOSITORY and RESTIC_PASSWORD must be defined in ${ENV_FILE}." >&2
  exit 1
fi

show_help() {
  cat <<EOF
Restic Helper Wrapper
Repository: ${RESTIC_REPOSITORY}

Usage:
  $(basename "$0") <command> [arguments...]

Convenience Shortcuts:
  snapshots                List all snapshots in repository
  latest                   Show the most recent snapshot
  prune [options]          Prune old snapshots using retention schedule
                           (Defaults: 7 daily, 4 weekly, 6 monthly)
                           Schedule Options:
                             -d, --daily,   --keep-daily N     Keep last N daily (0 to disable)
                             -w, --weekly,  --keep-weekly N    Keep last N weekly (0 to disable)
                             -m, --monthly, --keep-monthly N   Keep last N monthly (0 to disable)
                             -y, --yearly,  --keep-yearly N    Keep last N yearly
                             -l, --last,    --keep-last N      Keep last N snapshots
                             -n, --dry-run                     Simulate without deleting
                           Examples:
                             $(basename "$0") prune
                             $(basename "$0") prune -d 14 -w 8 -m 12
                             $(basename "$0") prune --daily 30 --weekly 0 --dry-run
  find <pattern>           Search for a file pattern across all snapshots
  restore-latest <dir>     Restore the latest snapshot to the target directory
  check [--read-data]      Verify repository integrity
  unlock                   Remove stale lock files after an interrupted run
  stats                    Show storage statistics for the repository

Direct Restic Passthrough:
  Any standard restic command can be passed directly with credentials pre-loaded.
  Examples:
    $(basename "$0") ls latest
    $(basename "$0") restore <snapshot_id> --target /tmp/restore --include /path/to/file
    $(basename "$0") diff <id1> <id2>
    $(basename "$0") backup /path/to/dir
    $(basename "$0") mount /tmp/restic-mount

EOF
}

if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

COMMAND="$1"
shift

case "$COMMAND" in
  -h|--help|help)
    show_help
    exit 0
    ;;
  prune)
    # Default retention schedule from environment or defaults: 7 daily, 4 weekly, 6 monthly
    KEEP_DAILY="${PRUNE_KEEP_DAILY:-7}"
    KEEP_WEEKLY="${PRUNE_KEEP_WEEKLY:-4}"
    KEEP_MONTHLY="${PRUNE_KEEP_MONTHLY:-6}"
    KEEP_YEARLY="${PRUNE_KEEP_YEARLY:-}"
    KEEP_HOURLY="${PRUNE_KEEP_HOURLY:-}"
    KEEP_LAST="${PRUNE_KEEP_LAST:-}"

    EXTRA_PRUNE_ARGS=()

    while [[ $# -gt 0 ]]; do
      case "$1" in
        -d|--daily|--keep-daily)
          KEEP_DAILY="$2"
          shift 2
          ;;
        --daily=*|--keep-daily=*)
          KEEP_DAILY="${1#*=}"
          shift
          ;;
        -w|--weekly|--keep-weekly)
          KEEP_WEEKLY="$2"
          shift 2
          ;;
        --weekly=*|--keep-weekly=*)
          KEEP_WEEKLY="${1#*=}"
          shift
          ;;
        -m|--monthly|--keep-monthly)
          KEEP_MONTHLY="$2"
          shift 2
          ;;
        --monthly=*|--keep-monthly=*)
          KEEP_MONTHLY="${1#*=}"
          shift
          ;;
        -y|--yearly|--keep-yearly)
          KEEP_YEARLY="$2"
          shift 2
          ;;
        --yearly=*|--keep-yearly=*)
          KEEP_YEARLY="${1#*=}"
          shift
          ;;
        -H|--hourly|--keep-hourly)
          KEEP_HOURLY="$2"
          shift 2
          ;;
        --hourly=*|--keep-hourly=*)
          KEEP_HOURLY="${1#*=}"
          shift
          ;;
        -l|--last|--keep-last)
          KEEP_LAST="$2"
          shift 2
          ;;
        --last=*|--keep-last=*)
          KEEP_LAST="${1#*=}"
          shift
          ;;
        *)
          EXTRA_PRUNE_ARGS+=("$1")
          shift
          ;;
      esac
    done

    PRUNE_CMD_ARGS=()
    SUMMARY_PARTS=()

    if [[ -n "$KEEP_DAILY" && "$KEEP_DAILY" != "0" && "$KEEP_DAILY" != "none" ]]; then
      PRUNE_CMD_ARGS+=(--keep-daily "$KEEP_DAILY")
      SUMMARY_PARTS+=("${KEEP_DAILY} daily")
    fi
    if [[ -n "$KEEP_WEEKLY" && "$KEEP_WEEKLY" != "0" && "$KEEP_WEEKLY" != "none" ]]; then
      PRUNE_CMD_ARGS+=(--keep-weekly "$KEEP_WEEKLY")
      SUMMARY_PARTS+=("${KEEP_WEEKLY} weekly")
    fi
    if [[ -n "$KEEP_MONTHLY" && "$KEEP_MONTHLY" != "0" && "$KEEP_MONTHLY" != "none" ]]; then
      PRUNE_CMD_ARGS+=(--keep-monthly "$KEEP_MONTHLY")
      SUMMARY_PARTS+=("${KEEP_MONTHLY} monthly")
    fi
    if [[ -n "$KEEP_YEARLY" && "$KEEP_YEARLY" != "0" && "$KEEP_YEARLY" != "none" ]]; then
      PRUNE_CMD_ARGS+=(--keep-yearly "$KEEP_YEARLY")
      SUMMARY_PARTS+=("${KEEP_YEARLY} yearly")
    fi
    if [[ -n "$KEEP_HOURLY" && "$KEEP_HOURLY" != "0" && "$KEEP_HOURLY" != "none" ]]; then
      PRUNE_CMD_ARGS+=(--keep-hourly "$KEEP_HOURLY")
      SUMMARY_PARTS+=("${KEEP_HOURLY} hourly")
    fi
    if [[ -n "$KEEP_LAST" && "$KEEP_LAST" != "0" && "$KEEP_LAST" != "none" ]]; then
      PRUNE_CMD_ARGS+=(--keep-last "$KEEP_LAST")
      SUMMARY_PARTS+=("last ${KEEP_LAST}")
    fi

    PRUNE_CMD_ARGS+=(--prune)

    POLICY_STR=$(printf ", %s" "${SUMMARY_PARTS[@]}")
    POLICY_STR="${POLICY_STR:2}"
    echo "Running restic forget & prune (keeping ${POLICY_STR:-no policy specified})..."
    exec "$RESTIC_BIN" forget "${PRUNE_CMD_ARGS[@]}" "${EXTRA_PRUNE_ARGS[@]}"
    ;;
  snapshots)
    exec "$RESTIC_BIN" snapshots "$@"
    ;;
  latest)
    exec "$RESTIC_BIN" snapshots --latest 1 "$@"
    ;;
  find)
    if [[ $# -eq 0 ]]; then
      echo "Error: 'find' requires a pattern or filename to search for." >&2
      exit 1
    fi
    exec "$RESTIC_BIN" find "$@"
    ;;
  restore-latest)
    if [[ $# -eq 0 ]]; then
      echo "Error: 'restore-latest' requires a target directory." >&2
      echo "Usage: $(basename "$0") restore-latest <target_dir> [restic-options...]" >&2
      exit 1
    fi
    TARGET_DIR="$1"
    shift
    echo "Restoring latest snapshot to: ${TARGET_DIR}"
    exec "$RESTIC_BIN" restore latest --target "$TARGET_DIR" "$@"
    ;;
  check)
    exec "$RESTIC_BIN" check "$@"
    ;;
  unlock)
    exec "$RESTIC_BIN" unlock "$@"
    ;;
  stats)
    exec "$RESTIC_BIN" stats "$@"
    ;;
  *)
    exec "$RESTIC_BIN" "$COMMAND" "$@"
    ;;
esac
