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
