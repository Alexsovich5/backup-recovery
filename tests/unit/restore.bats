#!/usr/bin/env bats
# Tests for scripts/restore.sh command building and control flow, run
# against the bconsole stub and the transcripts in tests/fixtures/bconsole/.

ROOT="$BATS_TEST_DIRNAME/../.."
RESTORE="$ROOT/scripts/restore.sh"

setup() {
  WORK="$BATS_TMPDIR/restore.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  export BCONSOLE_SEQUENCE="$WORK/sequence"
  export BCONSOLE_LOG="$WORK/bconsole.log"
  export BCONSOLE_CURSOR="$WORK/cursor"
  export BCONSOLE_CONF="$WORK/bconsole.conf"
  export LOG_FILE="$WORK/restore.log"
  export WAIT_INTERVAL=0
  : > "$BCONSOLE_LOG"
  : > "$BCONSOLE_SEQUENCE"
}

teardown() {
  rm -rf "$WORK"
}

sequence() {
  printf '%s\n' "$@" > "$BCONSOLE_SEQUENCE"
}

@test "--dry-run prints the default restore command and contacts nobody" {
  run "$RESTORE" --client server01 --where /tmp/x --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = 'restore client=server01-fd restoreclient=server01-fd where=/tmp/x select current all done yes' ]
  [ ! -s "$BCONSOLE_LOG" ]
}

@test "without --where the restore goes to /tmp/bacula-restores" {
  run "$RESTORE" --client server01 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *' where=/tmp/bacula-restores '* ]]
}

@test "--before selects the backups before that time instead of current" {
  run "$RESTORE" --client server01 --where /tmp/x --before '2014-01-10 12:00:00' --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *'before="2014-01-10 12:00:00"'* ]]
  [[ "$output" != *current* ]]
}

@test "--before with a malformed time exits 2" {
  run "$RESTORE" --client server01 --before 'yesterday' --dry-run
  [ "$status" -eq 2 ]
}

@test "--jobid restores that job" {
  run "$RESTORE" --client server01 --jobid 5 --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *' jobid=5 '* ]]
  [[ "$output" != *current* ]]
}

@test "--jobid must be a number" {
  run "$RESTORE" --client server01 --jobid five --dry-run
  [ "$status" -eq 2 ]
}

@test "--file selects only the given files" {
  run "$RESTORE" --client server01 --file a --file b --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *' file=a file=b '* ]]
  [[ "$output" != *' all '* ]]
}

@test "--restore-client sends the files to another FD" {
  run "$RESTORE" --client server01 --restore-client backup-fd --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == 'restore client=server01-fd restoreclient=backup-fd '* ]]
}

@test "a client already named with -fd is used as is" {
  run "$RESTORE" --client server01-fd --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == 'restore client=server01-fd restoreclient=server01-fd '* ]]
}

@test "missing --client prints usage and exits 2" {
  run "$RESTORE" --where /tmp/x --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *Usage:* ]]
}

@test "unknown option exits 2" {
  run "$RESTORE" --client server01 --bogus
  [ "$status" -eq 2 ]
  [ ! -s "$BCONSOLE_LOG" ]
}

@test "director down exits 3 and sends no restore" {
  sequence status-dir-refused.txt
  run "$RESTORE" --client server01 --where /tmp/x
  [ "$status" -eq 3 ]
  run grep -c '^restore ' "$BCONSOLE_LOG"
  [ "$output" = "0" ]
}

@test "restore ending in T exits 0 after sending the command once" {
  sequence status-dir-ok.txt restore-queued.txt list-jobid-T.txt
  run "$RESTORE" --client server01 --where /tmp/x
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep '^restore ' "$BCONSOLE_LOG")" = 'restore client=server01-fd restoreclient=server01-fd where=/tmp/x select current all done yes' ]
  grep -q 'JobId 42' "$LOG_FILE"
}

@test "restore status f exits 1" {
  sequence status-dir-ok.txt restore-queued.txt list-jobid-f.txt
  run "$RESTORE" --client server01 --where /tmp/x
  [ "$status" -eq 1 ]
  grep -q 'ERROR: .*status f' "$LOG_FILE"
}

@test "restore that is not queued exits 1" {
  sequence status-dir-ok.txt status-dir-ok.txt
  run "$RESTORE" --client server01 --where /tmp/x
  [ "$status" -eq 1 ]
}
