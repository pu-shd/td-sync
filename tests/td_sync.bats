#!/usr/bin/env bats

setup() {
  PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export PROJECT_ROOT
  export TD_HOME="$PROJECT_ROOT"
  export TD_TEST_MODE=1
  export PATH="$PROJECT_ROOT/bin:$PATH"
  export TD_MOCK_OUTPUT="$BATS_TEST_TMPDIR/mock.log"
  export HOME="$BATS_TEST_TMPDIR/home"
  unset TD_CONFIG_DIR
  unset TD_LOG_DIR
  unset TD_LOG_RETENTION_DAYS
  unset TD_RSYNC_OPTS
  mkdir -p "$HOME"
  rm -f "$TD_MOCK_OUTPUT"
}

teardown() {
  rm -f "$TD_MOCK_OUTPUT"
}

@test "shows help text" {
  run "$PROJECT_ROOT/bin/td-sync" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tiny Data Sync"* ]]
  [[ "$output" == *"TD_TEST_MODE"* ]]
}

@test "initial run creates default config dir and reports absence" {
  unset TD_CONFIG_DIR
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -eq 0 ]
  [[ -d "$HOME/.config/td-sync.d" ]]
  [[ "$output" == *"No configuration profiles found"* ]]
}

@test "invalid profile fails with helpful error" {
  config_dir="$BATS_TEST_TMPDIR/config"
  mkdir -p "$config_dir"
  cat >"$config_dir/invalid.env" <<'EOF'
TD_SRC=/tmp/source
TD_SUBMIT_INTERVAL=3600
EOF
  export TD_CONFIG_DIR="$config_dir"
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TD_DEST is required"* ]]
}

@test "valid profile writes job script and submits via sbatch" {
  config_dir="$BATS_TEST_TMPDIR/config-valid"
  log_dir="$BATS_TEST_TMPDIR/logs"
  mkdir -p "$config_dir" "$log_dir"
  cat >"$config_dir/sample.env" <<'EOF'
TD_SRC=/data/src
TD_DEST=/data/dest
TD_SUBMIT_INTERVAL=3600
TD_SLURM_ACCOUNT=research
TD_NOTIFY=ops@example.com
TD_DRY_RUN=1
TD_SLURM_RUNTIME=02:30:00
TD_RSYNC_OPTS="--exclude .venv --delete"
EOF
  export TD_CONFIG_DIR="$config_dir"
  export TD_LOG_DIR="$log_dir"
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -eq 0 ]
  [[ -f "$PROJECT_ROOT/jobs/sample.job.sh" ]]
  job_script_contents="$(cat "$PROJECT_ROOT/jobs/sample.job.sh")"
  [[ "$job_script_contents" == *"TD_NOTIFY=ops@example.com"* ]]
  [[ "$job_script_contents" == *"TD_DRY_RUN=1"* ]]
  [[ "$job_script_contents" == *"TD_RSYNC_OPTS=--exclude\\ .venv\\ --delete"* ]]
  mock_log="$(cat "$TD_MOCK_OUTPUT")"
  [[ "$mock_log" == *"--account=research"* ]]
  [[ "$mock_log" == *"--time=02:30:00"* ]]
}

@test "log retention purges stale td-sync logs only" {
  config_dir="$BATS_TEST_TMPDIR/config-retain"
  mkdir -p "$config_dir"
  cat >"$config_dir/keep.env" <<'EOF'
TD_SRC=/data/src
TD_DEST=/data/dest
TD_SUBMIT_INTERVAL=7days
EOF
  export TD_CONFIG_DIR="$config_dir"
  export TD_LOG_DIR="$BATS_TEST_TMPDIR/logs-retain"
  mkdir -p "$TD_LOG_DIR/td-sync"
  old_log="$TD_LOG_DIR/td-sync/keep_20200101T000000.log"
  old_out="$TD_LOG_DIR/td-sync/keep_slurm-1.out"
  unrelated_log="$TD_LOG_DIR/someone-else.log"
  touch -d '3 days ago' "$old_log" "$old_out" "$unrelated_log"
  export TD_LOG_RETENTION_DAYS=1
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -eq 0 ]
  [[ ! -e "$old_log" ]]
  [[ ! -e "$old_out" ]]
  [[ -e "$unrelated_log" ]]
}

@test "logs go to a td-sync subdirectory of TD_LOG_DIR from the environment" {
  config_dir="$BATS_TEST_TMPDIR/config-envlog"
  mkdir -p "$config_dir"
  cp "$PROJECT_ROOT/tests/tmp.env" "$config_dir/envlog.env"
  export TD_CONFIG_DIR="$config_dir"
  export TD_LOG_DIR="$BATS_TEST_TMPDIR/shared-logs"
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -eq 0 ]
  [[ -d "$TD_LOG_DIR/td-sync" ]]
  grep -qxF "TD_LOG_DIR=$TD_LOG_DIR/td-sync" "$PROJECT_ROOT/jobs/envlog.job.sh"
}

@test "TD_LOG_DIR set in a profile overrides the environment" {
  config_dir="$BATS_TEST_TMPDIR/config-proflog"
  profile_logs="$BATS_TEST_TMPDIR/profile-logs"
  mkdir -p "$config_dir"
  cp "$PROJECT_ROOT/tests/tmp.env" "$config_dir/proflog.env"
  printf 'TD_LOG_DIR=%s\n' "$profile_logs" >>"$config_dir/proflog.env"
  export TD_CONFIG_DIR="$config_dir"
  export TD_LOG_DIR="$BATS_TEST_TMPDIR/env-logs"
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -eq 0 ]
  [[ -d "$profile_logs/td-sync" ]]
  grep -qxF "TD_LOG_DIR=$profile_logs/td-sync" "$PROJECT_ROOT/jobs/proflog.job.sh"
}

@test "relative TD_LOG_DIR in a profile is rejected" {
  config_dir="$BATS_TEST_TMPDIR/config-rellog"
  mkdir -p "$config_dir"
  cp "$PROJECT_ROOT/tests/tmp.env" "$config_dir/rellog.env"
  printf 'TD_LOG_DIR=relative/logs\n' >>"$config_dir/rellog.env"
  export TD_CONFIG_DIR="$config_dir"
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TD_LOG_DIR must be an absolute path"* ]]
}

# Writes tests/tmp.env as profile $1 plus any extra lines, then runs td-sync.
submit_profile_fixture() {
  local name="$1"
  shift
  local config_dir="$BATS_TEST_TMPDIR/config-$name"
  mkdir -p "$config_dir"
  cp "$PROJECT_ROOT/tests/tmp.env" "$config_dir/$name.env"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$config_dir/$name.env"
  done
  export TD_CONFIG_DIR="$config_dir"
  export TD_LOG_DIR="$BATS_TEST_TMPDIR/logs-$name"
  "$PROJECT_ROOT/bin/td-sync"
  rm -f "$TD_MOCK_OUTPUT"
}

run_job() {
  run env PATH="$PROJECT_ROOT/mocks/bin:$PATH" SLURM_JOB_ID=777 "$PROJECT_ROOT/jobs/$1.job.sh"
}

@test "job schedules its next run before rsync, dependent on itself" {
  submit_profile_fixture early
  run_job early
  [ "$status" -eq 0 ]
  sbatch_line="$(grep -n '^sbatch ' "$TD_MOCK_OUTPUT" | cut -d: -f1)"
  rsync_line="$(grep -n '^rsync ' "$TD_MOCK_OUTPUT" | cut -d: -f1)"
  [ -n "$sbatch_line" ]
  [ -n "$rsync_line" ]
  [ "$sbatch_line" -lt "$rsync_line" ]
  grep -q -- '--dependency=afterany:777' "$TD_MOCK_OUTPUT"
  grep -q -- '--begin=now+30' "$TD_MOCK_OUTPUT"
  ! grep -q '^scancel' "$TD_MOCK_OUTPUT"
}

@test "next run survives when the job is killed mid-rsync" {
  submit_profile_fixture killed
  export TD_MOCK_RSYNC_KILL_PARENT=1
  run_job killed
  [ "$status" -ne 0 ]
  grep -q '^sbatch .*--dependency=afterany:777' "$TD_MOCK_OUTPUT"
  ! grep -q '^scancel' "$TD_MOCK_OUTPUT"
}

@test "rsync failure cancels the already scheduled next run" {
  submit_profile_fixture failing
  export TD_MOCK_RSYNC_STATUS=11 TD_MOCK_JOB_ID=4242
  run_job failing
  [ "$status" -eq 11 ]
  grep -qx 'scancel 4242' "$TD_MOCK_OUTPUT"
  latest_log="$(ls -t "$TD_LOG_DIR"/td-sync/failing_*.log | head -1)"
  grep -q 'rsync exited with status 11' "$latest_log"
}

@test "failed requeue submission is logged and rsync still runs" {
  submit_profile_fixture noqueue
  export TD_MOCK_SBATCH_STATUS=1
  run_job noqueue
  [ "$status" -eq 0 ]
  grep -q '^rsync ' "$TD_MOCK_OUTPUT"
  latest_log="$(ls -t "$TD_LOG_DIR"/td-sync/noqueue_*.log | head -1)"
  grep -q 'Unable to requeue job' "$latest_log"
}

@test "td-sync refreshes the job script but does not resubmit an already queued profile" {
  submit_profile_fixture queued
  rm -f "$PROJECT_ROOT/jobs/queued.job.sh"
  export TD_MOCK_SQUEUE_OUTPUT=$'555\n556'
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already queued"* ]]
  [[ -f "$PROJECT_ROOT/jobs/queued.job.sh" ]]
  grep -q '^squeue .*-n td-sync-queued' "$TD_MOCK_OUTPUT"
  ! grep -q '^sbatch' "$TD_MOCK_OUTPUT"
}

@test "td-sync does not submit when squeue fails" {
  submit_profile_fixture sqfail
  export TD_MOCK_SQUEUE_STATUS=1
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unable to query squeue"* ]]
  ! grep -q '^sbatch' "$TD_MOCK_OUTPUT"
}
