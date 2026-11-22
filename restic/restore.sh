#!/usr/bin/env bash
# ==============================================================================
# restore.sh: Restore files or snapshots from the configured Restic repository
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTIC_DIR="${RESTIC_DIR:-$HOME/restic}"

if [[ -z "${ENV_FILE:-}" ]]; then
  if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    ENV_FILE="${SCRIPT_DIR}/.env"
  else
    ENV_FILE="${RESTIC_DIR}/.env"
  fi
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: Environment file not found at ${ENV_FILE}. Run setup_restic.sh first." >&2
  exit 1
fi

CALLER_RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
CALLER_RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
CALLER_RESTIC_BIN="${RESTIC_BIN:-}"

# Load RESTIC_REPOSITORY, RESTIC_PASSWORD, RESTIC_BIN, BACKUP_PATHS from .env
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -n "$CALLER_RESTIC_REPOSITORY" ]]; then
  export RESTIC_REPOSITORY="$CALLER_RESTIC_REPOSITORY"
fi
if [[ -n "$CALLER_RESTIC_PASSWORD" ]]; then
  export RESTIC_PASSWORD="$CALLER_RESTIC_PASSWORD"
fi
if [[ -n "$CALLER_RESTIC_BIN" ]]; then
  export RESTIC_BIN="$CALLER_RESTIC_BIN"
fi

# Locate restic binary
RESTIC_BIN="${RESTIC_BIN:-${SCRIPT_DIR}/restic}"
if [[ ! -x "$RESTIC_BIN" ]]; then
  if [[ -x "${RESTIC_DIR}/restic" ]]; then
    RESTIC_BIN="${RESTIC_DIR}/restic"
  elif command -v restic &>/dev/null; then
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

usage() {
  cat <<EOF
Restic Restore Script
Repository: ${RESTIC_REPOSITORY}

Usage:
  $(basename "$0") <target_dir> [include_path...]
  $(basename "$0") [options] [-- extra_restic_args...]

Restore Options:
  -t, --target <dir>       Target directory to extract files into
      --in-place           Restore directly to original absolute paths (--target /)
  -s, --snapshot <id>      Snapshot ID to restore from (default: latest)
  -r, --repo <url>         Override RESTIC_REPOSITORY URL
      --from <host-user>   Switch repo on the same server to <host-user> (e.g. n8n-prod-01-production)
  -p, --password-file <f>  Read repository password from file instead of .env
  -i, --include <path>     Include only matching path/pattern (repeatable)
  -e, --exclude <path>     Exclude matching path/pattern (repeatable)
      --verify             Verify restored files after extraction
  -n, --dry-run            Preview files that would be restored (--dry-run -v)

Inspection Modes:
  -l, --list               List all snapshots in the repository
  -f, --find <pattern>     Search for a file/directory pattern across snapshots
      --ls [path]          List files in the snapshot (optionally under [path])
      --dump <path>        Print a single file from the snapshot to stdout
  -h, --help               Show this help message

Examples:
  # List available snapshots
  $(basename "$0") --list

  # Restore entire latest snapshot to /tmp/restore
  $(basename "$0") /tmp/restore

  # Restore specific folder(s) from the latest snapshot to /tmp/restore
  $(basename "$0") /tmp/restore "${HOME}/luna-strategy-Trading/Trading/config"

  # Preview restoring a path from a specific snapshot
  $(basename "$0") -s latest -t /tmp/restore -i "${HOME}/luna-strategy-Trading/Trading/config" --dry-run

  # Restore a specific path in-place to its original location
  $(basename "$0") --in-place -i "${HOME}/luna-strategy-Trading/Trading/config"

  # Dump a single file to stdout
  $(basename "$0") --dump "${HOME}/luna-strategy-Trading/Trading/README.md" > /tmp/README.md

  # List or restore from another server/user's repository
  $(basename "$0") --list --from n8n-prod-01-production
  $(basename "$0") /tmp/restore-prod --from n8n-prod-01-production
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

SNAPSHOT="latest"
TARGET_DIR=""
IN_PLACE=false
DRY_RUN=false
VERIFY=false
MODE="restore"
FIND_PATTERN=""
DUMP_PATH=""
INCLUDES=()
EXCLUDES=()
EXTRA_ARGS=()
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help)
      usage
      exit 0
      ;;
    -s|--snapshot)
      SNAPSHOT="$2"
      shift 2
      ;;
    --snapshot=*)
      SNAPSHOT="${1#*=}"
      shift
      ;;
    -r|--repo)
      if [[ "$2" == http://* || "$2" == https://* ]]; then
        export RESTIC_REPOSITORY="rest:$2"
      else
        export RESTIC_REPOSITORY="$2"
      fi
      shift 2
      ;;
    --repo=*)
      REPO_VAL="${1#*=}"
      if [[ "$REPO_VAL" == http://* || "$REPO_VAL" == https://* ]]; then
        export RESTIC_REPOSITORY="rest:${REPO_VAL}"
      else
        export RESTIC_REPOSITORY="$REPO_VAL"
      fi
      shift
      ;;
    --from)
      if [[ "$2" == rest:* ]]; then
        export RESTIC_REPOSITORY="$2"
      elif [[ "$2" == http://* || "$2" == https://* ]]; then
        export RESTIC_REPOSITORY="rest:$2"
      else
        FROM_TARGET="${2%/}"
        BASE_REPO="${RESTIC_REPOSITORY%/}"
        BASE_SERVER="${BASE_REPO%/*}"
        export RESTIC_REPOSITORY="${BASE_SERVER}/${FROM_TARGET}/"
      fi
      shift 2
      ;;
    --from=*)
      FROM_TARGET="${1#*=}"
      if [[ "$FROM_TARGET" == rest:* ]]; then
        export RESTIC_REPOSITORY="$FROM_TARGET"
      elif [[ "$FROM_TARGET" == http://* || "$FROM_TARGET" == https://* ]]; then
        export RESTIC_REPOSITORY="rest:${FROM_TARGET}"
      else
        FROM_TARGET="${FROM_TARGET%/}"
        BASE_REPO="${RESTIC_REPOSITORY%/}"
        BASE_SERVER="${BASE_REPO%/*}"
        export RESTIC_REPOSITORY="${BASE_SERVER}/${FROM_TARGET}/"
      fi
      shift
      ;;
    -p|--password-file)
      export RESTIC_PASSWORD_FILE="$2"
      unset RESTIC_PASSWORD
      shift 2
      ;;
    --password-file=*)
      export RESTIC_PASSWORD_FILE="${1#*=}"
      unset RESTIC_PASSWORD
      shift
      ;;
    -t|--target)
      TARGET_DIR="$2"
      shift 2
      ;;
    --target=*)
      TARGET_DIR="${1#*=}"
      shift
      ;;
    --in-place)
      IN_PLACE=true
      shift
      ;;
    -i|--include)
      INCLUDES+=("$2")
      shift 2
      ;;
    --include=*)
      INCLUDES+=("${1#*=}")
      shift
      ;;
    -e|--exclude)
      EXCLUDES+=("$2")
      shift 2
      ;;
    --exclude=*)
      EXCLUDES+=("${1#*=}")
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    --verify)
      VERIFY=true
      shift
      ;;
    -l|--list|snapshots)
      MODE="list"
      shift
      ;;
    -f|--find)
      MODE="find"
      FIND_PATTERN="$2"
      shift 2
      ;;
    --find=*)
      MODE="find"
      FIND_PATTERN="${1#*=}"
      shift
      ;;
    --ls)
      MODE="ls"
      shift
      ;;
    --dump)
      MODE="dump"
      DUMP_PATH="$2"
      shift 2
      ;;
    --dump=*)
      MODE="dump"
      DUMP_PATH="${1#*=}"
      shift
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    -*)
      EXTRA_ARGS+=("$1")
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

case "$MODE" in
  list)
    exec "$RESTIC_BIN" snapshots "${POSITIONAL[@]}" "${EXTRA_ARGS[@]}"
    ;;
  find)
    if [[ -z "$FIND_PATTERN" ]]; then
      echo "Error: --find requires a file pattern." >&2
      exit 1
    fi
    exec "$RESTIC_BIN" find "$FIND_PATTERN" "${POSITIONAL[@]}" "${EXTRA_ARGS[@]}"
    ;;
  ls)
    exec "$RESTIC_BIN" ls "$SNAPSHOT" "${POSITIONAL[@]}" "${EXTRA_ARGS[@]}"
    ;;
  dump)
    if [[ -z "$DUMP_PATH" ]]; then
      echo "Error: --dump requires a file path inside the snapshot." >&2
      exit 1
    fi
    exec "$RESTIC_BIN" dump "$SNAPSHOT" "$DUMP_PATH" "${EXTRA_ARGS[@]}"
    ;;
esac

if [[ "$IN_PLACE" == true ]]; then
  if [[ -n "$TARGET_DIR" && "$TARGET_DIR" != "/" ]]; then
    echo "Error: Cannot combine --in-place with --target ${TARGET_DIR}." >&2
    exit 1
  fi
  TARGET_DIR="/"
  for p in "${POSITIONAL[@]}"; do
    INCLUDES+=("$p")
  done
else
  if [[ -z "$TARGET_DIR" ]]; then
    if [[ ${#POSITIONAL[@]} -eq 0 ]]; then
      echo "Error: Target directory is required (use <target_dir>, --target <dir>, or --in-place)." >&2
      echo "" >&2
      usage >&2
      exit 1
    fi
    TARGET_DIR="${POSITIONAL[0]}"
    for p in "${POSITIONAL[@]:1}"; do
      INCLUDES+=("$p")
    done
  else
    for p in "${POSITIONAL[@]}"; do
      INCLUDES+=("$p")
    done
  fi
fi

if [[ "$TARGET_DIR" != "/" ]]; then
  mkdir -p "$TARGET_DIR"
fi

RESTORE_ARGS=("$SNAPSHOT" --target "$TARGET_DIR")

for inc in "${INCLUDES[@]}"; do
  RESTORE_ARGS+=(--include "$inc")
done

for exc in "${EXCLUDES[@]}"; do
  RESTORE_ARGS+=(--exclude "$exc")
done

if [[ "$VERIFY" == true ]]; then
  RESTORE_ARGS+=(--verify)
fi

if [[ "$DRY_RUN" == true ]]; then
  RESTORE_ARGS+=(--dry-run -v)
fi

RESTORE_ARGS+=("${EXTRA_ARGS[@]}")

echo "Restoring snapshot '${SNAPSHOT}' from ${RESTIC_REPOSITORY} to '${TARGET_DIR}'..."
if [[ ${#INCLUDES[@]} -gt 0 ]]; then
  echo "  Includes: ${INCLUDES[*]}"
fi
if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
  echo "  Excludes: ${EXCLUDES[*]}"
fi
if [[ "$DRY_RUN" == true ]]; then
  echo "  Mode:     DRY RUN (no files will be written)"
fi

exec "$RESTIC_BIN" restore "${RESTORE_ARGS[@]}"
