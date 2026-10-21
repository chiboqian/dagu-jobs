# dagu-jobs

Bootstrap and migration scripts for running a [Dagu](https://github.com/dagucloud/dagu) worker on a host, converting the current user's `crontab` entries into Dagu DAG definitions, and importing them into the central Dagu server.

## Overview

| Script | Purpose |
| :--- | :--- |
| `./setup_worker.sh` | Downloads the latest `dagu` binary to `~/jobs/bin/dagu`, creates `~/jobs/run_worker.sh` with `worker.id=<hostname>-<user>` and `worker.labels=host=<hostname>,user=<user>`, and enables/starts a user-level `systemd` service (`dagu-worker.service`). |
| `./cron_to_dagu.sh` | Reads the current user's `crontab -l` (or a file), converts all cron jobs into Dagu YAML definitions under `~/jobs/dags/` with matching `worker_selector` labels, and validates them with `dagu validate`. |
| `./import_dags.sh` | Authenticates against the Dagu server API using username/password and creates or updates all `.yaml` workflows from `~/jobs/dags/`. |

*(Generated artifacts `bin/`, `run_worker.sh`, and `dags/` are git-ignored.)*

---

## Quick Start (Onboard a Host/User)

```bash
git clone git@github.com:chiboqian/dagu-jobs.git ~/jobs
cd ~/jobs

# 1. Install Dagu worker & start user-level systemd service
./setup_worker.sh jobs.luna-strategy.com

# 2. Convert current user's crontab into ~/jobs/dags/*.yaml
./cron_to_dagu.sh

# 3. Import generated DAGs into the Dagu server
./import_dags.sh
```

---

## Script Reference

### 1. `setup_worker.sh`

Downloads the `dagu` binary for the current OS/architecture into `~/jobs/bin/dagu`, generates `~/jobs/run_worker.sh`, and configures `~/.config/systemd/user/dagu-worker.service`.

```bash
./setup_worker.sh <COORDINATOR_HOST> [COORDINATOR_PORT]
```

**Example:**
```bash
./setup_worker.sh jobs.luna-strategy.com
```

**Worker Identity & Labels:**
- `--worker.id`: `$(hostname -s)-$(whoami)` (e.g., `llm-01-backtest01`)
- `--worker.labels`: `host=$(hostname -s),user=$(whoami)` (e.g., `host=llm-01,user=backtest01`)

**Managing the Systemd User Service:**
```bash
systemctl --user status dagu-worker
journalctl --user -u dagu-worker -f
systemctl --user restart dagu-worker
systemctl --user stop dagu-worker
```

---

### 2. `cron_to_dagu.sh`

Converts the current user's `crontab` into validated Dagu YAML definitions in `~/jobs/dags/`.

- Preserves preceding `#` comments as the DAG `description`.
- Merges identical commands that run on multiple cron schedules into a single DAG with a multi-schedule list.
- Extracts leading `cd /path && ...` into Dagu's `working_dir` field.
- Pins each generated DAG to the current host and user via `worker_selector`:
  ```yaml
  worker_selector:
    host: "<hostname>"
    user: "<username>"
  ```
- Validates every generated `.yaml` file using `~/jobs/bin/dagu validate`.

```bash
# Convert current user's crontab into ~/jobs/dags
./cron_to_dagu.sh

# Custom output directory or input crontab file
./cron_to_dagu.sh --output-dir /path/to/dags --file /path/to/crontab
```

---

### 3. `import_dags.sh`

Logs into the Dagu server REST API (`/api/v1/auth/login`) with a Dagu username and password, then creates or updates all `.yaml` DAG definitions in `~/jobs/dags/`.

```bash
# Interactive prompt for username and password
./import_dags.sh

# Pass credentials as arguments or flags
./import_dags.sh <DAGU_USER> <DAGU_PASSWORD>
./import_dags.sh -u <DAGU_USER> -p <DAGU_PASSWORD> -s http://jobs.luna-strategy.com:8080
```

**Environment Variables:**
- `DAGU_SERVER`: Dagu web server URL (default: `http://jobs.luna-strategy.com:8080`)
- `DAGU_USER`: Dagu username
- `DAGU_PASSWORD`: Dagu password
- `DAGS_DIR`: Directory containing `.yaml` files (default: `~/jobs/dags`)
