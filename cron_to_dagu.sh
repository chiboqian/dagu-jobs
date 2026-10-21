#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/dags}"
DAGU_BIN="${DAGU_BIN:-${SCRIPT_DIR}/bin/dagu}"
CRONTAB_FILE=""

usage() {
  cat <<EOF
Usage: $0 [options]

Convert the current user's crontab entries into Dagu DAG YAML files.

Options:
  -o, --output-dir DIR    Directory to write Dagu YAML files (default: ${SCRIPT_DIR}/dags)
  -f, --file FILE         Read crontab from FILE instead of 'crontab -l'
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -f|--file)
      CRONTAB_FILE="$2"
      shift 2
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

mkdir -p "$OUTPUT_DIR"

python3 - "$OUTPUT_DIR" "$CRONTAB_FILE" <<'PYEOF'
import getpass
import os
import re
import shlex
import socket
import subprocess
import sys
from collections import OrderedDict

output_dir = sys.argv[1]
crontab_file = sys.argv[2]
host_short = socket.gethostname().split(".")[0]
current_user = getpass.getuser()

if crontab_file:
    with open(crontab_file, "r", encoding="utf-8") as f:
        raw_lines = f.read().splitlines()
else:
    proc = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
    if proc.returncode != 0:
        if "no crontab for" in proc.stderr.lower():
            print("No crontab found for current user.")
            sys.exit(0)
        sys.stderr.write(proc.stderr)
        sys.exit(proc.returncode)
    raw_lines = proc.stdout.splitlines()

SPECIAL_SCHEDULES = {
    "@yearly", "@annually", "@monthly", "@weekly",
    "@daily", "@midnight", "@hourly", "@reboot"
}

ENV_LINE_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")
CRON_5_RE = re.compile(r"^(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.+)$")
CRON_SPECIAL_RE = re.compile(r"^(@\S+)\s+(.+)$")


MAX_NAME_LEN = 38  # Dagu requires DAG names to be < 40 characters


def derive_name(cmd: str) -> str:
    # Strip redirections at the end
    cleaned = re.sub(r"\s*(?:>>|>|2>&1|2>>|2>|<)\s*\S+", " ", cmd).strip()
    # If there is a 'cd ... &&', take the part after the last &&
    parts = [p.strip() for p in cleaned.split("&&") if p.strip()]
    main_cmd = parts[-1] if parts else cleaned

    try:
        tokens = shlex.split(main_cmd)
    except ValueError:
        tokens = main_cmd.split()

    # Drop leading inline env vars (KEY=VAL) and interpreter binaries
    idx = 0
    while idx < len(tokens) and "=" in tokens[idx] and not tokens[idx].startswith("-"):
        idx += 1

    interpreters = {"bash", "sh", "zsh", "python", "python3", "node", "ruby", "perl"}
    while idx < len(tokens):
        base = os.path.basename(tokens[idx])
        if base in interpreters or base.startswith("python3."):
            idx += 1
        else:
            break

    tokens_rem = tokens[idx:] if idx < len(tokens) else tokens
    if not tokens_rem:
        return "cron_job"

    # Unwrap generic cron wrapper scripts like run_cron_job.sh [--no-email] <actual_script> ...
    first_base = os.path.splitext(os.path.basename(tokens_rem[0]))[0].lower()
    if first_base in {"run_cron_job", "cron_wrapper", "wrapper"} and len(tokens_rem) > 1:
        j = 1
        while j < len(tokens_rem) and tokens_rem[j].startswith("-"):
            j += 1
        while j < len(tokens_rem):
            b = os.path.basename(tokens_rem[j])
            if b in interpreters or b.startswith("python3."):
                j += 1
            else:
                break
        if j < len(tokens_rem):
            tokens_rem = tokens_rem[j:]

    script_path = tokens_rem[0]
    script_base = os.path.splitext(os.path.basename(script_path))[0]
    parent_dir = os.path.basename(os.path.dirname(script_path.rstrip("/")))

    # If the script name is generic (e.g. nightly, run, start, main), prepend parent folder name
    if script_base.lower() in {"nightly", "run", "main", "start", "index", "job"} and parent_dir:
        name_parts = [parent_dir, script_base]
    else:
        name_parts = [script_base]

    # Inspect arguments for distinguishing subcommands/flags
    args = tokens_rem[1:]
    skip_next = False
    for i, arg in enumerate(args):
        if skip_next:
            skip_next = False
            continue
        if arg in {"--wait-until", "--email", "--no-email"}:
            if arg == "--wait-until":
                skip_next = True
            continue
        if arg in {"--config", "-c", "--instance", "--r2-object"} and i + 1 < len(args):
            cfg_base = os.path.splitext(os.path.basename(args[i + 1]))[0]
            name_parts.append(cfg_base)
            skip_next = True
            continue
        if arg.startswith("--"):
            flag_name = arg.lstrip("-").split("=")[0]
            if flag_name in {"report"}:
                name_parts.append(flag_name)
        elif not arg.startswith("-"):
            val_base = os.path.splitext(os.path.basename(arg))[0]
            if not val_base.startswith(".") and val_base.lower() not in {"env", "none", "active"}:
                name_parts.append(val_base)

    slug = "_".join(name_parts)
    slug = re.sub(r"[^A-Za-z0-9_]+", "_", slug)
    slug = re.sub(r"_+", "_", slug).strip("_").lower()
    if len(slug) > MAX_NAME_LEN:
        slug = slug[:MAX_NAME_LEN].rstrip("_")
    return slug or "cron_job"


def extract_working_dir_and_cmd(cmd: str):
    # Match leading 'cd <path> && <rest>'
    m = re.match(r"^cd\s+([^\s&;]+)\s*&&\s*(.+)$", cmd)
    if m:
        return m.group(1), m.group(2)
    return None, cmd


def yaml_quote(val: str) -> str:
    escaped = val.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


global_env = OrderedDict()
pending_comments = []
jobs_by_cmd = OrderedDict()

for raw in raw_lines:
    line = raw.strip()
    if not line:
        pending_comments = []
        continue
    # Support re-running after disable_cron.sh has prefixed lines with '# [Replaced by Dagu]'
    if line.startswith("# [Replaced by Dagu]"):
        line = line[len("# [Replaced by Dagu]"):].strip()
    elif line.startswith("#"):
        comment_text = line.lstrip("#").strip()
        if (
            comment_text
            and not comment_text.startswith("=== MIGRATED TO DAGU ===")
            and not comment_text.startswith("Disabled on ")
        ):
            pending_comments.append(comment_text)
        continue

    # Check if this is a cron line first
    m_special = CRON_SPECIAL_RE.match(line)
    m_cron5 = CRON_5_RE.match(line)

    schedule = None
    command = None

    if m_special and m_special.group(1).lower() in SPECIAL_SCHEDULES:
        schedule = m_special.group(1)
        command = m_special.group(2).strip()
    elif m_cron5 and not ENV_LINE_RE.match(line):
        schedule = m_cron5.group(1)
        command = m_cron5.group(2).strip()
    else:
        m_env = ENV_LINE_RE.match(line)
        if m_env:
            key, val = m_env.group(1), m_env.group(2).strip()
            if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
                val = val[1:-1]
            global_env[key] = val
            pending_comments = []
            continue

    if schedule and command:
        # In standard crontab, \% is an escaped literal %
        command = command.replace(r"\%", "%")
        if command not in jobs_by_cmd:
            jobs_by_cmd[command] = {
                "schedules": [schedule],
                "comments": list(pending_comments),
                "env": OrderedDict(global_env),
            }
        else:
            if schedule not in jobs_by_cmd[command]["schedules"]:
                jobs_by_cmd[command]["schedules"].append(schedule)
            for c in pending_comments:
                if c not in jobs_by_cmd[command]["comments"]:
                    jobs_by_cmd[command]["comments"].append(c)
        pending_comments = []

used_names = set()
generated_files = []

# Remove stale .yaml files in output_dir before writing new ones
for existing in os.listdir(output_dir):
    if existing.endswith(".yaml"):
        try:
            os.remove(os.path.join(output_dir, existing))
        except OSError:
            pass

host_user_prefix = re.sub(r"[^A-Za-z0-9_]+", "_", f"{host_short}_{current_user}")
host_user_prefix = re.sub(r"_+", "_", host_user_prefix).strip("_").lower()

for command, info in jobs_by_cmd.items():
    short_job = derive_name(command)
    # Strip redundant prefix if short_job already starts with host or user name
    for pfx in (f"{host_user_prefix}_", f"{current_user.lower()}_"):
        if short_job.startswith(pfx) and len(short_job) > len(pfx):
            short_job = short_job[len(pfx):]
    base_name = f"{host_user_prefix}_{short_job}"
    dag_name = base_name[:39].rstrip("_")
    counter = 2
    while dag_name in used_names:
        suffix = f"_{counter}"
        trimmed = base_name[: 39 - len(suffix)].rstrip("_")
        dag_name = f"{trimmed}{suffix}"
        counter += 1
    used_names.add(dag_name)

    work_dir, step_cmd = extract_working_dir_and_cmd(command)
    description = " ".join(info["comments"]) if info["comments"] else f"Converted from crontab: {base_name}"

    yaml_lines = [
        f"# Converted from user crontab ({dag_name})",
        f"description: {yaml_quote(description)}",
    ]

    schedules = info["schedules"]
    if len(schedules) == 1:
        yaml_lines.append(f"schedule: {yaml_quote(schedules[0])}")
    else:
        yaml_lines.append("schedule:")
        for sched in schedules:
            yaml_lines.append(f"  - {yaml_quote(sched)}")

    yaml_lines.extend([
        "labels:",
        f"  host: {yaml_quote(host_short)}",
        f"  user: {yaml_quote(current_user)}",
        "worker_selector:",
        f"  host: {yaml_quote(host_short)}",
        f"  user: {yaml_quote(current_user)}",
        'shell: "/bin/bash"',
    ])

    if work_dir:
        yaml_lines.append(f"working_dir: {yaml_quote(work_dir)}")

    if info["env"]:
        yaml_lines.append("env:")
        for k, v in info["env"].items():
            yaml_lines.append(f"  - {k}: {yaml_quote(v)}")

    yaml_lines.extend([
        "steps:",
        f"  - name: {dag_name}",
        f"    run: {yaml_quote(step_cmd)}",
    ])

    out_path = os.path.join(output_dir, f"{dag_name}.yaml")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(yaml_lines) + "\n")
    generated_files.append((dag_name, schedules, out_path))

print(f"Converted {len(generated_files)} Dagu job(s) into {output_dir}:")
for dag_name, schedules, out_path in generated_files:
    sched_str = ", ".join(schedules)
    print(f"  - {dag_name:<30} [{sched_str}] -> {out_path}")
PYEOF

# Validate all generated DAGs if dagu binary exists
if [[ -x "$DAGU_BIN" ]]; then
  echo ""
  echo "Validating generated DAGs with ${DAGU_BIN}..."
  TMP_DAGU_HOME="$(mktemp -d)"
  trap 'rm -rf "$TMP_DAGU_HOME"' EXIT
  mkdir -p "$TMP_DAGU_HOME/dags"
  touch "$TMP_DAGU_HOME/dags/.examples-created"
  shopt -s nullglob
  for dag_file in "$OUTPUT_DIR"/*.yaml; do
    DAGU_AUTH_MODE=none "$DAGU_BIN" validate --dagu-home "$TMP_DAGU_HOME" "$dag_file" >/dev/null
  done
  echo "All generated DAGs passed validation."
fi
