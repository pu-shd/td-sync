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
  ! grep -q '^scancel' "$TD_MOCK_OUTPUT" || false
}

@test "next run survives when the job is killed mid-rsync" {
  submit_profile_fixture killed
  export TD_MOCK_RSYNC_KILL_PARENT=1
  run_job killed
  [ "$status" -ne 0 ]
  grep -q '^sbatch .*--dependency=afterany:777' "$TD_MOCK_OUTPUT"
  ! grep -q '^scancel' "$TD_MOCK_OUTPUT" || false
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
  ! grep -q '^sbatch' "$TD_MOCK_OUTPUT" || false
}

@test "td-sync does not submit when squeue fails" {
  submit_profile_fixture sqfail
  export TD_MOCK_SQUEUE_STATUS=1
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unable to query squeue"* ]]
  ! grep -q '^sbatch' "$TD_MOCK_OUTPUT" || false
}

@test "Slurm emails the first recipient on failure and writes output next to the logs" {
  config_dir="$BATS_TEST_TMPDIR/config-slurmmail"
  mkdir -p "$config_dir"
  cp "$PROJECT_ROOT/tests/tmp.env" "$config_dir/slurmmail.env"
  printf 'TD_NOTIFY="a@example.org, b@example.org"\n' >>"$config_dir/slurmmail.env"
  export TD_CONFIG_DIR="$config_dir"
  export TD_LOG_DIR="$BATS_TEST_TMPDIR/logs-slurmmail"
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -eq 0 ]
  grep -qF -- "--mail-type=FAIL,TIME_LIMIT_90 --mail-user=a@example.org" "$TD_MOCK_OUTPUT"
  grep -qF -- "--output=$TD_LOG_DIR/td-sync/slurmmail_slurm-%j.out" "$TD_MOCK_OUTPUT"
  rm -f "$TD_MOCK_OUTPUT"
  run_job slurmmail
  [ "$status" -eq 0 ]
  grep -q '^sbatch --parsable .*--mail-type=FAIL,TIME_LIMIT_90 --mail-user=a@example.org' "$TD_MOCK_OUTPUT"
  grep -qF -- "--output=$TD_LOG_DIR/td-sync/slurmmail_slurm-%j.out" "$TD_MOCK_OUTPUT"
}

@test "no Slurm mail options without TD_NOTIFY" {
  submit_profile_fixture nomail
  run "$PROJECT_ROOT/bin/td-sync"
  ! grep -q -- '--mail-type' "$TD_MOCK_OUTPUT" || false
  grep -q -- '--output=' "$TD_MOCK_OUTPUT"
}

@test "healthchecks gets a start ping and an exit-status ping with the summary" {
  submit_profile_fixture hc "TD_HC_URL=https://hc-ping.com/0f1e2d3c-aaaa-bbbb-cccc-1234567890ab/"
  run_job hc
  [ "$status" -eq 0 ]
  start_line="$(grep -n 'curl .*\[https://hc-ping.com/0f1e2d3c-aaaa-bbbb-cccc-1234567890ab/start\]' "$TD_MOCK_OUTPUT" | cut -d: -f1)"
  rsync_line="$(grep -n '^rsync ' "$TD_MOCK_OUTPUT" | cut -d: -f1)"
  [ -n "$start_line" ]
  [ "$start_line" -lt "$rsync_line" ]
  grep -q 'curl .*\[https://hc-ping.com/0f1e2d3c-aaaa-bbbb-cccc-1234567890ab/0\]' "$TD_MOCK_OUTPUT"
  grep -q 'Rsync exit status: 0' "$TD_MOCK_OUTPUT.curl-body"
}

@test "partial transfer (rsync 23/24) reports failure but keeps the next run" {
  local code
  for code in 23 24; do
    submit_profile_fixture "partial$code"
    export TD_MOCK_RSYNC_STATUS=$code TD_MOCK_JOB_ID=4242
    run_job "partial$code"
    [ "$status" -eq "$code" ]
    ! grep -q '^scancel' "$TD_MOCK_OUTPUT" || false
    latest_log="$(ls -t "$TD_LOG_DIR"/td-sync/partial${code}_*.log | head -1)"
    grep -q "rsync exited with status $code" "$latest_log"
    grep -q "Next run (job 4242) kept" "$latest_log"
    rm -f "$TD_MOCK_OUTPUT"
  done
}

@test "healthchecks receives the rsync exit status on failure" {
  submit_profile_fixture hcfail "TD_HC_URL=https://hc-ping.com/abc"
  export TD_MOCK_RSYNC_STATUS=23
  run_job hcfail
  [ "$status" -eq 23 ]
  grep -q 'curl .*\[https://hc-ping.com/abc/23\]' "$TD_MOCK_OUTPUT"
}

@test "healthchecks is told to fail when the next run cannot be scheduled" {
  submit_profile_fixture hcnoqueue "TD_HC_URL=https://hc-ping.com/abc"
  export TD_MOCK_SBATCH_STATUS=1
  run_job hcnoqueue
  grep -q 'curl .*\[https://hc-ping.com/abc/fail\]' "$TD_MOCK_OUTPUT"
}

@test "pings and mail go through TD_RELAY_HOST with arguments intact" {
  submit_profile_fixture relay "TD_HC_URL=https://hc-ping.com/abc" "TD_RELAY_HOST=della9" "TD_NOTIFY=ops@example.org"
  run_job relay
  [ "$status" -eq 0 ]
  grep -q '^ssh della9 .*curl .*hc-ping.com/abc/start' "$TD_MOCK_OUTPUT"
  grep -q '^ssh della9 .*curl .*hc-ping.com/abc/0' "$TD_MOCK_OUTPUT"
  grep -q '^ssh della9 .*mail' "$TD_MOCK_OUTPUT"
  grep -qxF 'mail [-s] [Tiny Data Sync results for td-sync-relay] [ops@example.org]' "$TD_MOCK_OUTPUT"
  grep -q 'Rsync exit status: 0' "$TD_MOCK_OUTPUT.curl-body"
}

@test "unreachable relay, ping, or mailer never fails the job or the schedule" {
  submit_profile_fixture flaky "TD_HC_URL=https://hc-ping.com/abc" "TD_RELAY_HOST=della9" "TD_NOTIFY=ops@example.org"
  export TD_MOCK_SSH_STATUS=255
  run_job flaky
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthchecks ping /start failed"* ]]
  [[ "$output" == *"unable to email report to ops@example.org"* ]]
  grep -q '^sbatch --parsable' "$TD_MOCK_OUTPUT"
  ! grep -q '^scancel' "$TD_MOCK_OUTPUT" || false
}

@test "unsafe TD_HC_URL is rejected" {
  config_dir="$BATS_TEST_TMPDIR/config-badhc"
  mkdir -p "$config_dir"
  cp "$PROJECT_ROOT/tests/tmp.env" "$config_dir/badhc.env"
  printf 'TD_HC_URL='"'"'https://hc-ping.com/x;touch /tmp/pwned'"'"'\n' >>"$config_dir/badhc.env"
  export TD_CONFIG_DIR="$config_dir"
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TD_HC_URL must be an https:// URL"* ]]
}

@test "unsafe TD_RELAY_HOST is rejected" {
  config_dir="$BATS_TEST_TMPDIR/config-badrelay"
  mkdir -p "$config_dir"
  cp "$PROJECT_ROOT/tests/tmp.env" "$config_dir/badrelay.env"
  printf 'TD_RELAY_HOST=-oProxyCommand=evil\n' >>"$config_dir/badrelay.env"
  export TD_CONFIG_DIR="$config_dir"
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TD_RELAY_HOST must be a plain host name"* ]]
}

@test "report email is throttled per profile" {
  submit_profile_fixture throttle "TD_NOTIFY=a@example.org,b@example.org"
  run_job throttle
  [ "$status" -eq 0 ]
  run_job throttle
  [ "$status" -eq 0 ]
  [[ "$output" == *"report email suppressed"* ]]
  [ "$(grep -c '^mail ' "$TD_MOCK_OUTPUT")" -eq 2 ]
}

@test "TD_NOTIFY_MIN_INTERVAL=0 disables email throttling" {
  submit_profile_fixture nothrottle "TD_NOTIFY=a@example.org" "TD_NOTIFY_MIN_INTERVAL=0"
  run_job nothrottle
  run_job nothrottle
  [ "$status" -eq 0 ]
  [ "$(grep -c '^mail ' "$TD_MOCK_OUTPUT")" -eq 2 ]
}

@test "failed email does not start the throttle window" {
  submit_profile_fixture mailfail "TD_NOTIFY=a@example.org"
  export TD_MOCK_MAIL_STATUS=1
  run_job mailfail
  [ "$status" -eq 0 ]
  unset TD_MOCK_MAIL_STATUS
  run_job mailfail
  [[ "$output" != *"suppressed"* ]]
  [ "$(grep -c '^mail ' "$TD_MOCK_OUTPUT")" -eq 2 ]
}

@test "non-numeric TD_NOTIFY_MIN_INTERVAL is rejected" {
  config_dir="$BATS_TEST_TMPDIR/config-badthrottle"
  mkdir -p "$config_dir"
  cp "$PROJECT_ROOT/tests/tmp.env" "$config_dir/badthrottle.env"
  printf 'TD_NOTIFY_MIN_INTERVAL=1h\n' >>"$config_dir/badthrottle.env"
  export TD_CONFIG_DIR="$config_dir"
  run "$PROJECT_ROOT/bin/td-sync"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TD_NOTIFY_MIN_INTERVAL must be a whole number of seconds"* ]]
}

# Builds a source tree with a conda env, a venv, an env nested inside an env,
# and ordinary data, under $BATS_TEST_TMPDIR/envsrc/proj.
make_env_tree() {
  local root="$BATS_TEST_TMPDIR/envsrc/proj"
  mkdir -p "$root/plain_named_env/conda-meta" "$root/plain_named_env/lib" \
    "$root/plain_named_env/pkgs/inner/conda-meta" \
    "$root/code/venv_like" "$root/data/results" "$root/odd[name]*env/conda-meta"
  touch "$root/code/venv_like/pyvenv.cfg" "$root/data/results/table.csv" "$root/plain_named_env/lib/libbig.so"
  printf '%s\n' "$root"
}

@test "TD_EXCLUDE_ENVS excludes directories that contain conda-meta or pyvenv.cfg" {
  root="$(make_env_tree)"
  submit_profile_fixture envs "TD_SRC=$root/" "TD_EXCLUDE_ENVS=1"
  run_job envs
  [ "$status" -eq 0 ]
  grep -q -- '--exclude-from=' "$TD_MOCK_OUTPUT"
  excludes="$(cat "$TD_MOCK_OUTPUT.exclude-from")"
  [ "$(wc -l <<<"$excludes")" -eq 3 ]
  grep -qxF '/plain_named_env/' <<<"$excludes"
  grep -qxF '/code/venv_like/' <<<"$excludes"
  grep -qxF '/odd\[name\]\*env/' <<<"$excludes"
  latest_log="$(ls -t "$TD_LOG_DIR"/td-sync/envs_*.log | head -1)"
  grep -q 'Excluded 3 environment directories' "$latest_log"
}

@test "environment excludes are anchored at the source basename without a trailing slash" {
  root="$(make_env_tree)"
  submit_profile_fixture envbase "TD_SRC=$root" "TD_EXCLUDE_ENVS=1"
  run_job envbase
  [ "$status" -eq 0 ]
  grep -qxF '/proj/plain_named_env/' "$TD_MOCK_OUTPUT.exclude-from"
}

@test "environment excludes come before user rsync filters" {
  root="$(make_env_tree)"
  submit_profile_fixture envorder "TD_SRC=$root/" "TD_EXCLUDE_ENVS=1" "TD_RSYNC_OPTS=\"--filter='+ *'\""
  run_job envorder
  rsync_line="$(grep '^rsync ' "$TD_MOCK_OUTPUT")"
  before_user="${rsync_line%%--filter=+ \**}"
  [[ "$before_user" == *"--exclude-from="* ]]
}

@test "environment detection is off by default" {
  root="$(make_env_tree)"
  submit_profile_fixture envoff "TD_SRC=$root/"
  run_job envoff
  [ "$status" -eq 0 ]
  ! grep -q -- '--exclude-from=' "$TD_MOCK_OUTPUT" || false
}

@test "environment detection is skipped with a warning for a remote source" {
  submit_profile_fixture envremote "TD_SRC=host:/data/src/" "TD_EXCLUDE_ENVS=1"
  run_job envremote
  [ "$status" -eq 0 ]
  ! grep -q -- '--exclude-from=' "$TD_MOCK_OUTPUT" || false
  grep -q '^rsync ' "$TD_MOCK_OUTPUT"
  latest_log="$(ls -t "$TD_LOG_DIR"/td-sync/envremote_*.log | head -1)"
  grep -q 'TD_EXCLUDE_ENVS ignored' "$latest_log"
}

@test "real rsync skips detected environments and copies everything else" {
  real_rsync="$(PATH="${PATH//$PROJECT_ROOT\/mocks\/bin/}" command -v rsync || true)"
  [ -n "$real_rsync" ] || skip "real rsync not installed"
  root="$(make_env_tree)"
  dest="$BATS_TEST_TMPDIR/envdest"
  mkdir -p "$dest"
  submit_profile_fixture envreal "TD_SRC=$root/" "TD_DEST=$dest/" "TD_EXCLUDE_ENVS=1"
  tools="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$tools"
  for tool in sbatch squeue scancel; do ln -sf "$PROJECT_ROOT/mocks/bin/$tool" "$tools/$tool"; done
  ln -sf "$real_rsync" "$tools/rsync"
  run env PATH="$tools:$PATH" SLURM_JOB_ID=777 "$PROJECT_ROOT/jobs/envreal.job.sh"
  [ "$status" -eq 0 ]
  [[ -f "$dest/data/results/table.csv" ]]
  [[ ! -e "$dest/plain_named_env" ]]
  [[ ! -e "$dest/code/venv_like" ]]
  [[ ! -e "$dest/odd[name]*env" ]]
}

# Builds a project with a `pip install --target` directory mixed with user files,
# under $BATS_TEST_TMPDIR/pipsrc/proj.
make_pip_tree() {
  local root="$BATS_TEST_TMPDIR/pipsrc/proj"
  local tgt="$root/exp/9"
  mkdir -p "$tgt/pkg/sub" "$tgt/pkg.libs" "$tgt/pkg-1.0.dist-info" "$tgt/we,ird" "$tgt/bin" \
    "$root/exp/fom.egg-info" "$root/env1/conda-meta" "$root/env1/lib/dep-2.0.dist-info"
  touch "$tgt/pkg/__init__.py" "$tgt/pkg/sub/core.so" "$tgt/pkg.libs/libx.so" "$tgt/mod.py" \
    "$tgt/we,ird/f" "$tgt/bin/tool" "$tgt/keepme.py" "$root/exp/run.py" "$root/exp/fom.egg-info/PKG-INFO"
  cat >"$tgt/pkg-1.0.dist-info/RECORD" <<'RECORD'
pkg/__init__.py,sha256=abc,10
pkg/sub/core.so,sha256=def,20
pkg.libs/libx.so,,
mod.py,sha256=ghi,5
"we,ird/f",,
bin/tool,,
../../bin/f2py,,
pkg-1.0.dist-info/RECORD,,
RECORD
  printf 'dep-2.0.dist-info/RECORD,,\n' >"$root/env1/lib/dep-2.0.dist-info/RECORD"
  printf '%s\n' "$root"
}

@test "TD_EXCLUDE_ENVS excludes exactly the paths pip recorded for --target installs" {
  root="$(make_pip_tree)"
  submit_profile_fixture pip "TD_SRC=$root/" "TD_EXCLUDE_ENVS=1"
  run_job pip
  [ "$status" -eq 0 ]
  excludes="$(cat "$TD_MOCK_OUTPUT.exclude-from")"
  expected=$'/env1/\n/exp/9/mod.py\n/exp/9/pkg\n/exp/9/pkg-1.0.dist-info\n/exp/9/pkg.libs\n/exp/9/we,ird'
  [ "$(sort <<<"$excludes")" = "$expected" ]
  latest_log="$(ls -t "$TD_LOG_DIR"/td-sync/pip_*.log | head -1)"
  grep -q 'Excluding pip-installed pkg-1.0 in exp/9 (5 paths)' "$latest_log"
}

@test "real rsync skips pip-installed packages but keeps neighboring user files" {
  real_rsync="$(PATH="${PATH//$PROJECT_ROOT\/mocks\/bin/}" command -v rsync || true)"
  [ -n "$real_rsync" ] || skip "real rsync not installed"
  root="$(make_pip_tree)"
  dest="$BATS_TEST_TMPDIR/pipdest"
  mkdir -p "$dest"
  submit_profile_fixture pipreal "TD_SRC=$root/" "TD_DEST=$dest/" "TD_EXCLUDE_ENVS=1"
  tools="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$tools"
  for tool in sbatch squeue scancel; do ln -sf "$PROJECT_ROOT/mocks/bin/$tool" "$tools/$tool"; done
  ln -sf "$real_rsync" "$tools/rsync"
  run env PATH="$tools:$PATH" SLURM_JOB_ID=777 "$PROJECT_ROOT/jobs/pipreal.job.sh"
  [ "$status" -eq 0 ]
  [[ -f "$dest/exp/9/keepme.py" ]]
  [[ -f "$dest/exp/9/bin/tool" ]]
  [[ -f "$dest/exp/run.py" ]]
  [[ -f "$dest/exp/fom.egg-info/PKG-INFO" ]]
  [[ ! -e "$dest/exp/9/pkg" ]]
  [[ ! -e "$dest/exp/9/pkg.libs" ]]
  [[ ! -e "$dest/exp/9/mod.py" ]]
  [[ ! -e "$dest/exp/9/pkg-1.0.dist-info" ]]
  [[ ! -e "$dest/exp/9/we,ird" ]]
  [[ ! -e "$dest/env1" ]]
}

@test "next run is scheduled before the environment scan" {
  root="$(make_env_tree)"
  submit_profile_fixture scanorder "TD_SRC=$root/" "TD_EXCLUDE_ENVS=1"
  tools="$BATS_TEST_TMPDIR/tools-scanorder"
  mkdir -p "$tools"
  real_find="$(command -v find)"
  printf '#!/usr/bin/env bash\nprintf "find\\n" >>"$TD_MOCK_OUTPUT"\nexec %q "$@"\n' "$real_find" >"$tools/find"
  chmod +x "$tools/find"
  run env PATH="$tools:$PROJECT_ROOT/mocks/bin:$PATH" SLURM_JOB_ID=777 "$PROJECT_ROOT/jobs/scanorder.job.sh"
  [ "$status" -eq 0 ]
  sbatch_line="$(grep -n '^sbatch ' "$TD_MOCK_OUTPUT" | cut -d: -f1)"
  find_line="$(grep -n '^find$' "$TD_MOCK_OUTPUT" | head -1 | cut -d: -f1)"
  [ -n "$sbatch_line" ]
  [ -n "$find_line" ]
  [ "$sbatch_line" -lt "$find_line" ]
}

@test "conda package caches are excluded whole and site-packages is not scanned for pip installs" {
  root="$BATS_TEST_TMPDIR/cachesrc/proj"
  mkdir -p "$root/.conda/pkgs/cache" "$root/.conda/pkgs/numpy-2.0/site-packages/numpy-2.0.dist-info" \
    "$root/py/lib/python3.12/site-packages/six-1.0.dist-info" "$root/tgt/six-1.0.dist-info"
  touch "$root/.conda/pkgs/urls.txt"
  printf 'numpy/__init__.py,,\n' >"$root/.conda/pkgs/numpy-2.0/site-packages/numpy-2.0.dist-info/RECORD"
  printf 'six.py,,\n' >"$root/py/lib/python3.12/site-packages/six-1.0.dist-info/RECORD"
  printf 'six.py,,\n' >"$root/tgt/six-1.0.dist-info/RECORD"
  submit_profile_fixture cache "TD_SRC=$root/" "TD_EXCLUDE_ENVS=1"
  run_job cache
  [ "$status" -eq 0 ]
  expected=$'/.conda/pkgs/\n/tgt/six.py'
  [ "$(sort "$TD_MOCK_OUTPUT.exclude-from")" = "$expected" ]
}
