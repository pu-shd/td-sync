# Tiny Data Sync

Tiny Data Sync schedules recurring `rsync` synchronizations through Slurm.

The script ingests `.env` configuration profiles and produces self-resubmitting batch jobs that keep pairs of directories in sync on a somewhat predictable cadence.

## Features

- Auto-discovers configuration profiles from `$HOME/.config/td-sync.d` or `$TD_CONFIG_DIR`.
- Generates per-profile Slurm job scripts that execute `rsync`, log results, send notifications, and requeue themselves with `--begin=now+TD_SUBMIT_INTERVAL`.
- Schedules each next run *before* `rsync` starts (with `--dependency=afterany:<this job>`), so a time limit, node failure, or preemption cannot silently end the schedule. A genuine `rsync` failure cancels that next run.
- Skips submitting a profile that already has a job queued, so re-running `td-sync` never creates duplicate schedules.
- Writes logs to a dedicated `td-sync/` subdirectory of `$TD_LOG_DIR` (default `$PWD/logs`), with optional retention via `TD_LOG_RETENTION_DAYS`.
- Provides mock `sbatch`, `mail`, and `sendmail` utilities for isolated testing via `TD_TEST_MODE`.
- Ships a Docker test environment with `bats-core` for unit tests.

## Quick Start

```bash
# Run tests inside the provided Docker container
make test
```

To exercise the script locally without Docker:

```bash
export TD_TEST_MODE=1
./bin/td-sync --help
```

## Configuration Profiles

Each profile is a simple `.env` file. Required keys:

- `TD_SRC` – source path for `rsync`.
- `TD_DEST` – destination path for `rsync`.
- `TD_SUBMIT_INTERVAL` – Slurm delay (seconds or strings like `7days`).
- `TD_SLURM_ACCOUNT` – Slurm account (defaults to the profile filename when omitted).

Optional keys:

- `TD_NOTIFY` – comma-separated email recipients for the per-run report. The first recipient is also passed to Slurm (`--mail-type=FAIL,TIME_LIMIT_90`), so failures, timeouts, and approaching time limits are emailed by Slurm even when the job is killed before it can report.
- `TD_DRY_RUN` – `1` or `true` for `rsync --dry-run`.
- `TD_SLURM_RUNTIME` – job runtime (`HH:MM:SS`, defaults to `01:00:00`).
- `TD_RSYNC_OPTS` – additional `rsync` flags (e.g., `--exclude .venv --delete`).
- `TD_LOG_DIR` – absolute base directory for this profile's logs; overrides the `TD_LOG_DIR` environment variable.

## Test Mode

Setting `TD_TEST_MODE` to `1` or `true` prepends `mocks/bin` to `PATH`, replacing `sbatch`, `squeue`, `scancel`, `rsync`, `mail`, and `sendmail` with test doubles. Use this when running unit tests or developing on a system without Slurm or a mail transfer agent.

## Logs

Logs are always written to a `td-sync/` subdirectory of the log base directory (the profile's `TD_LOG_DIR`, else the `TD_LOG_DIR` environment variable, else `$PWD/logs`). Pointing `TD_LOG_DIR` at a shared directory such as `/scratch/gpfs/GROUP/logs` is therefore safe: other files there are never touched.

Slurm's own output for each job goes to `<profile>_slurm-<jobid>.out` beside the rsync logs rather than to the submission directory.

If `TD_LOG_RETENTION_DAYS` is set, Tiny Data Sync purges `*.log` and `*.out` files older than the configured number of days from that `td-sync/` subdirectory only, each time the script runs.

## Docker Image

The Dockerfile under `docker/` uses Debian Bookworm, respects the host architecture via `TARGETPLATFORM`, installs `bats-core`, and defaults to executing the Bats test suite.

## Example Usage

Below is a representative profile and command sequence for a project that mirrors data from a scratch volume to a long-term storage area every week:

1. Create a profile such as `~/ .config/td-sync.d/data-sync.env` containing:

	```env
	TD_SRC=/scratch/project/data/
	TD_DEST=/archive/project/data/
	TD_SUBMIT_INTERVAL=7days
	TD_SLURM_ACCOUNT=research
	TD_NOTIFY=user@example.edu
	TD_DRY_RUN=1
	TD_SLURM_RUNTIME=02:00:00
	TD_RSYNC_OPTS=--exclude .venv --delete
	```

2. Export any optional runtime variables, then execute the scheduler:

	```bash
	export TD_LOG_RETENTION_DAYS=7
	td-sync/bin/td-sync
	```

3. Tiny Data Sync will submit a Slurm job that performs an `rsync --dry-run`, writes a log under `logs/`, emails a short summary to the specified recipient, and requeues itself to run again after seven days. Switching `TD_DRY_RUN` to `0` promotes the synchronization from a preview to a real transfer. Any custom `TD_RSYNC_OPTS` (such as excluding `.venv`) are appended to the `rsync` invocation.

### Passing Complex rsync Filters

When `TD_RSYNC_OPTS` contains multiple arguments, quote values exactly as you would on the command line. For example:

```env
TD_RSYNC_OPTS="--filter='- .venv' --filter='- __pycache__'"
```

Tiny Data Sync evaluates these options inside the generated job script, so each quoted segment is preserved and forwarded to `rsync` without additional escaping.

