#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_FILE="${SCRIPT_DIR}/crontab.bak"
DRY_RUN=false
RESTORE=false

usage() {
  cat <<EOF
Usage: $0 [options]

Comment out active cronjobs in the current user's crontab and add a note
indicating they have been replaced by Dagu. Saves a backup to ${BACKUP_FILE}.

Options:
  -n, --dry-run    Print the updated crontab without installing it
  -r, --restore    Restore the crontab from ${BACKUP_FILE}
  -h, --help       Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -r|--restore)
      RESTORE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$RESTORE" == "true" ]]; then
  if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "Backup file not found: ${BACKUP_FILE}" >&2
    exit 1
  fi
  crontab "$BACKUP_FILE"
  echo "Restored crontab from ${BACKUP_FILE}."
  exit 0
fi

CURRENT_CRON="$(crontab -l 2>/dev/null || true)"
if [[ -z "$CURRENT_CRON" ]]; then
  echo "No crontab found for user $(whoami)."
  exit 0
fi

export CURRENT_CRON BACKUP_FILE DRY_RUN

python3 - <<'PYEOF'
import datetime
import os
import re
import subprocess
import sys

current_cron = os.environ["CURRENT_CRON"]
backup_file = os.environ["BACKUP_FILE"]
dry_run = os.environ["DRY_RUN"].lower() == "true"

SPECIAL_SCHEDULES = {
    "@yearly", "@annually", "@monthly", "@weekly",
    "@daily", "@midnight", "@hourly", "@reboot"
}
CRON_5_RE = re.compile(r"^(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.+)$")
CRON_SPECIAL_RE = re.compile(r"^(@\S+)\s+(.+)$")
ENV_LINE_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


def is_active_cron_entry(line: str) -> bool:
    s = line.strip()
    if not s or s.startswith("#"):
        return False
    m_special = CRON_SPECIAL_RE.match(s)
    if m_special and m_special.group(1).lower() in SPECIAL_SCHEDULES:
        return True
    if CRON_5_RE.match(s) and not ENV_LINE_RE.match(s):
        return True
    if ENV_LINE_RE.match(s):
        return True
    return False


lines = current_cron.splitlines()
active_count = sum(1 for line in lines if is_active_cron_entry(line))

if active_count == 0:
    print("All cronjobs are already commented out (0 active entries found).")
    sys.exit(0)

timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
header_marker = "# === MIGRATED TO DAGU ==="

new_lines = []
if not any(header_marker in l for l in lines):
    new_lines.extend([
        header_marker,
        f"# Disabled on {timestamp}: cronjobs below have been replaced by Dagu.",
        "",
    ])

for line in lines:
    if is_active_cron_entry(line):
        new_lines.append(f"# [Replaced by Dagu] {line}")
    else:
        new_lines.append(line)

updated_content = "\n".join(new_lines) + "\n"

if dry_run:
    print(f"--- Dry Run ({active_count} cron entry/entries would be commented out) ---")
    sys.stdout.write(updated_content)
    sys.exit(0)

# Save backup before modifying crontab
with open(backup_file, "w", encoding="utf-8") as f:
    f.write(current_cron if current_cron.endswith("\n") else current_cron + "\n")

proc = subprocess.run(["crontab", "-"], input=updated_content, text=True, capture_output=True)
if proc.returncode != 0:
    sys.stderr.write(f"Failed to update crontab:\n{proc.stderr}\n")
    sys.exit(proc.returncode)

print(f"Backed up original crontab to: {backup_file}")
print(f"Commented out {active_count} active cron entry/entries with '# [Replaced by Dagu]'.")
PYEOF
