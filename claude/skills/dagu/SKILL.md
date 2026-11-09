---
name: dagu
description: Read, check and change the scheduled jobs (Dagu DAGs) of every host — backtest01 and the production host — through the Dagu server's API. Use when the user asks what runs when, why a scheduled job failed, or to add, move or edit a job, its schedule, command or labels. Cron is no longer used on these hosts.
argument-hint: "[what to check or change, e.g. 'list production' or 'move sync_trades_r2 to 16:20']"
---

# Dagu jobs

Request: $ARGUMENTS

Every host's scheduled jobs run under Dagu, not cron. The old crontab lines on backtest01 are
commented `# [Replaced by Dagu]`. The repo's old copy of production's crontab, `PROD.cron`, was
deleted on 2026-11-03. The server is the source of truth.

- **Server:** `http://jobs.luna-strategy.com:8080`, API v1. The `/api/v2` paths return the web UI's HTML.
- **Key:** `DAGU_API_KEY` in `~/.config/dagu-jobs/api.env` (owner-only). It has full access. Never
  print it, pass it on a command line, or write it to a file; `dagu_jobs.py` reads it itself.
- **Time zone:** schedules are New York time.

## Hosts

| host / user | What runs there |
|---|---|
| `llm-01` / `backtest01` | This box: paper books, comparison and paper-review agents, P&L ledger, QQQ-direct job, paper health check, data cache, backups |
| `n8n-prod-01` / `production` | Production trading: engine and daemon start/stop, `sync_trades_r2`, log uploads, reports, live health check, `sync_alpaca_fees` |
| `n8n-prod-01` / `ibkr-01` | The IB Gateway user: weekly gateway stop/start/restart, its backups |

**Labels:** every job must have `host` and `user` labels equal to its `worker_selector`'s host and
user. Other labels are optional:

```yaml
labels:
  host: "n8n-prod-01"        # required, = worker_selector.host
  user: "production"         # required, = worker_selector.user
  type: "backup"             # optional; any further labels are fine
worker_selector:
  host: "n8n-prod-01"
  user: "production"
```

The `ibkr-01` jobs keep `user: "ibkr-01"`. Optional labels in use:
- `type`: added by the setup scripts in `~/dagu-jobs` (`setup_worker.sh`, `restic/setup_restic.sh`) to the
  backup, prune and update-client jobs;
- `momentum_paper_trading` (no value): the MomentumTrading paper-book jobs.

## The tool: `~/dagu-jobs/dagu_jobs.py`

It lives in the `dagu-jobs` repo (`git@github.com:chiboqian/dagu-jobs.git`), with this skill, so every
project uses the same copy. Run it from any directory with that repo's venv:

```bash
DJ="$HOME/dagu-jobs/.venv/bin/python $HOME/dagu-jobs/dagu_jobs.py"
$DJ list [--host n8n-prod-01] [--user production]
$DJ show JOB                 # spec, account numbers masked
$DJ runs JOB [-n 10]
$DJ log JOB [--run RUN_ID]   # latest run by default
$DJ export --out DIR [--host H] [--user U]   # raw specs, one per job
$DJ put JOB FILE [--create] [--yes]
```

- **Output is masked:** digit runs of 7+ (account numbers, in some job names and commands) and the
  key. Mask them in anything you show the user too.
- **Edit raw copies:** take the copy to edit from `export`, into the scratchpad, never from `show`.
  `put` refuses a spec that contains the masks.
- **New job:** write it in the existing jobs' format (copy one from `export`) and `put --create`.

## Changing a job

1. **Read first:** `list`, then `show` and `runs` for the job.
2. **Dry run:** edit an `export` copy and run `put` without `--yes`. It prints the diff against the
   live spec, warns about a missing or wrong `host`/`user` label, and changes nothing. Show the user
   that diff.
3. **Apply only on the user's OK for that change.**
   - Production (`n8n-prod-01`) jobs belong to the user: never change them on your own initiative,
     and approval of one change does not cover the next.
   - `put --yes` saves the live spec to `~/dagu-jobs/backups/<job>_<time>.yaml` (git-ignored),
     writes the new one and reads it back.
   - To undo: `put JOB <backup file> --yes`.
4. **Verify:** read the next run time `put` prints. After the job's first run, check `runs` / `log`.

**Code first:** a job that calls a script or flag production doesn't have yet fails until the user
pulls. One example is `--fees-only`, added in Trading's 5dc69b8. Say so, and suggest applying after the pull.

**Not supported:** deleting, suspending or triggering a job. Ask the user to do it in the web UI.

## Timing dependencies

Production's 16:05 `sync_trades_r2` (fills, orders, bars, and Alpaca fees from previous days) and
the 16:10/16:11 log uploads feed backtest01's evening jobs:
- `strategy_pnl_d1`: 16:40, retries until 21:00;
- `compare_today_agent`: 16:45, no wait, so it needs the fills already in R2;
- `qqqdirect_compare`: 18:00, retries until 21:00, and reads compare_today's output.

Alpaca posts a day's fees at about 20:05–20:20, so `sync_alpaca_fees` runs at 20:45.

Moving a job means checking what consumes its output. One more constraint: IBKR returns only the
current day's executions and clears them overnight, so the IBKR fills download must run the same
evening.

## Diagnosing a failed run

- **`log`** gives the scheduler log, each step's status and error (e.g. `exit status 1`) and the
  stderr tail.
- **No stdout:** the API does not serve a step's stdout. `log` prints its path on the worker,
  `/var/lib/dagu/logs/...`. Ask the user for it if the error isn't enough.
- **Health checks:** Trading's `util/account_health.py` exits 1 when any check is DOWN. Its email (and
  `trading_logs/health/<name>.log` on the host) says which.
