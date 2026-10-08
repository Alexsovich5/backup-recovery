#!/usr/bin/env bats
# Tests for scripts/lib/common.sh against the bconsole stub and the
# hand-written transcripts in tests/fixtures/bconsole/.

ROOT="$BATS_TEST_DIRNAME/../.."
FIXTURES="$ROOT/tests/fixtures/bconsole"

setup() {
  WORK="$BATS_TMPDIR/common.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  export BCONSOLE_SEQUENCE="$WORK/sequence"
  export BCONSOLE_LOG="$WORK/bconsole.log"
  export BCONSOLE_CURSOR="$WORK/cursor"
  export BCONSOLE_CONF="$WORK/bconsole.conf"
  export LOG_FILE="$WORK/backup.log"
  export WAIT_INTERVAL=0
  . "$ROOT/scripts/lib/common.sh"
}

teardown() {
  rm -rf "$WORK"
}

# sequence NAME... writes the fixture names the stub hands out in order.
sequence() {
  printf '%s\n' "$@" > "$BCONSOLE_SEQUENCE"
}

@test "parse_jobid extracts the JobId from a queued run" {
  run parse_jobid < "$FIXTURES/run-queued.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "42" ]
}

@test "parse_jobid fails when there is no JobId" {
  run parse_jobid < "$FIXTURES/status-dir-refused.txt"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "bconsole_cmd pipes the commands and quit into bconsole" {
  sequence run-queued.txt
  run bconsole_cmd 'run job="server01-full" yes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Job queued. JobId=42"* ]]
  [ "$(cat "$BCONSOLE_LOG")" = 'run job="server01-full" yes
quit' ]
}

@test "job_status returns T for a terminated job" {
  sequence list-jobid-T.txt
  run job_status 42
  [ "$status" -eq 0 ]
  [ "$output" = "T" ]
  [ "$(head -n 1 "$BCONSOLE_LOG")" = "list jobid=42" ]
}

@test "job_status returns f for a failed job" {
  sequence list-jobid-f.txt
  run job_status 42
  [ "$status" -eq 0 ]
  [ "$output" = "f" ]
}

@test "job_status fails when the JobId is not in the listing" {
  sequence list-jobid-T.txt
  run job_status 7
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "wait_job polls a running job until it is terminal" {
  sequence list-jobid-R.txt list-jobid-R.txt list-jobid-T.txt list-jobid-f.txt
  run wait_job 42
  [ "$status" -eq 0 ]
  [ "$output" = "T" ]
  [ "$(grep -c '^list jobid=42$' "$BCONSOLE_LOG")" -eq 3 ]
}

@test "wait_job gives up after WAIT_TIMEOUT seconds" {
  sequence list-jobid-R.txt list-jobid-R.txt list-jobid-R.txt list-jobid-R.txt
  WAIT_INTERVAL=1 WAIT_TIMEOUT=2 run wait_job 42
  [ "$status" -ne 0 ]
}

@test "wait_job does not depend on IFS to recognise a terminal status" {
  sequence list-jobid-T.txt
  IFS=$'\n'
  WAIT_TIMEOUT=0 run wait_job 42
  IFS=$' \t\n'
  [ "$status" -eq 0 ]
  [ "$output" = "T" ]
}

@test "wait_job treats D (verify differences) as terminal" {
  sequence list-jobid-D.txt
  WAIT_TIMEOUT=0 run wait_job 42
  [ "$status" -eq 0 ]
  [ "$output" = "D" ]
}

@test "bacula_name_ok accepts resource names and refuses quotes, blanks and newlines" {
  for n in server01 server01-fd backup-fd Verify-server01 a.b_c:d; do
    bacula_name_ok "$n"
  done
  for n in '' 'server01"' 'server 01' $'server01\nquit' 'srv;rm' '-fd' '../x'; do
    if bacula_name_ok "$n"; then
      echo "accepted: $n"
      return 1
    fi
  done
}

@test "bconsole_arg_ok refuses double quotes and control characters" {
  bconsole_arg_ok /srv/data/docs/runbook.txt
  bconsole_arg_ok '/srv/data/with space.txt'
  for v in '/tmp/x"y' $'/tmp/x\ndelete jobid=1' $'/tmp/x\ty' $'/tmp/x\ry'; do
    if bconsole_arg_ok "$v"; then
      echo "accepted: $v"
      return 1
    fi
  done
}

@test "check_manifest accepts make-manifest.sh output" {
  printf '%s  %s\n' 0123456789abcdef0123456789abcdef alpha.txt \
    0123456789abcdef0123456789abcdef 'docs/run book.txt' > "$WORK/m"
  run check_manifest "$WORK/m"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "check_manifest refuses absolute paths, .. components, escaped and malformed lines" {
  h=0123456789abcdef0123456789abcdef
  for bad in "$h  /etc/passwd" "$h  ../../clientdata/x" "$h  docs/../../x" "$h  .." \
             "\\$h  a\\nb" "not a checksum line" "$h  "; do
    printf '%s  %s\n%s\n' "$h" ok.txt "$bad" > "$WORK/m"
    run check_manifest "$WORK/m"
    echo "$bad -> $status $output"
    [ "$status" -ne 0 ]
  done
}

@test "check_manifest refuses an empty manifest" {
  : > "$WORK/m"
  run check_manifest "$WORK/m"
  [ "$status" -ne 0 ]
}

@test "director_up returns 0 when status dir answers" {
  sequence status-dir-ok.txt
  run director_up
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$BCONSOLE_LOG")" = "status dir" ]
}

@test "director_up returns 1 when the connection is refused" {
  sequence status-dir-refused.txt
  run director_up
  [ "$status" -eq 1 ]
}

@test "log_message appends a timestamped line to LOG_FILE" {
  run log_message "backup started"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LOG_FILE")" -eq 1 ]
  grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} - backup started$' "$LOG_FILE"
}

@test "die logs the message and exits with the given code" {
  run bash -c ". '$ROOT/scripts/lib/common.sh'; die 3 'director unreachable'; echo not-reached"
  [ "$status" -eq 3 ]
  [[ "$output" != *not-reached* ]]
  grep -q ' - ERROR: director unreachable$' "$LOG_FILE"
}
