#!/usr/bin/env bats
# Tests for scripts/queue-verify.sh, run against the bconsole stub and the
# transcripts in tests/fixtures/bconsole/.

QUEUE="$BATS_TEST_DIRNAME/../../scripts/queue-verify.sh"

setup() {
  WORK="$BATS_TMPDIR/queue-verify.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  export BCONSOLE_SEQUENCE="$WORK/sequence"
  export BCONSOLE_LOG="$WORK/bconsole.log"
  export BCONSOLE_CURSOR="$WORK/cursor"
  export BCONSOLE_CONF="$WORK/bconsole.conf"
  export BACKUP_CONF="$WORK/none.conf"
  export LOG_FILE="$WORK/queue.log"
  : > "$BCONSOLE_LOG"
}

teardown() {
  rm -rf "$WORK"
}

sequence() {
  printf '%s\n' "$@" > "$BCONSOLE_SEQUENCE"
}

@test "a client name that could inject bconsole commands exits 2 without contacting bconsole" {
  sequence run-queued.txt
  run "$QUEUE" $'server01\nquit'
  [ "$status" -eq 2 ]
  run "$QUEUE" 'server01" yes'
  [ "$status" -eq 2 ]
  [ ! -s "$BCONSOLE_LOG" ]
}

@test "queues Verify-<client> once, does not wait for it and exits 0" {
  sequence run-queued.txt
  run "$QUEUE" server01
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$BCONSOLE_LOG")" -eq 2 ]
  [ "$(head -n 1 "$BCONSOLE_LOG")" = 'run job="Verify-server01" yes' ]
  grep -q 'Queued Verify-server01 as JobId 42' "$LOG_FILE"
}

@test "a File Daemon name (as passed by %c) maps to the same verify job" {
  sequence run-queued.txt
  run "$QUEUE" server01-fd
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$BCONSOLE_LOG")" = 'run job="Verify-server01" yes' ]
}

@test "a verify that is not queued exits 1" {
  sequence status-dir-refused.txt
  run "$QUEUE" server01
  [ "$status" -eq 1 ]
  grep -q 'ERROR: .*Verify-server01' "$LOG_FILE"
}

@test "wrong argument count exits 2" {
  run "$QUEUE"
  [ "$status" -eq 2 ]
  run "$QUEUE" a b
  [ "$status" -eq 2 ]
  [ ! -s "$BCONSOLE_LOG" ]
}
