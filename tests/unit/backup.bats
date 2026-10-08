#!/usr/bin/env bats
# Tests for scripts/backup.sh argument handling and control flow, run
# against the bconsole stub and the transcripts in tests/fixtures/bconsole/.

ROOT="$BATS_TEST_DIRNAME/../.."
BACKUP="$ROOT/scripts/backup.sh"

setup() {
  WORK="$BATS_TMPDIR/backup.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK/volumes"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  export BCONSOLE_SEQUENCE="$WORK/sequence"
  export BCONSOLE_LOG="$WORK/bconsole.log"
  export BCONSOLE_CURSOR="$WORK/cursor"
  export BACKUP_CONF="$WORK/backup.conf"
  export BSMTP_LOG="$WORK/bsmtp.log"
  unset SMTP_HOST ADMIN_EMAIL
  cat > "$BACKUP_CONF" <<CONF
BCONSOLE_CONF=$WORK/bconsole.conf
LOG_FILE=$WORK/backup.log
VOLUME_DIR=$WORK/volumes
MIN_FREE_KB=1
WAIT_INTERVAL=0
CONF
  : > "$BCONSOLE_LOG"
}

teardown() {
  rm -rf "$WORK"
}

sequence() {
  printf '%s\n' "$@" > "$BCONSOLE_SEQUENCE"
}

# with_smtp adds SMTP settings to the backup.conf used by the test.
with_smtp() {
  cat >> "$BACKUP_CONF" <<CONF
SMTP_HOST=mailhost.test
ADMIN_EMAIL=ops@example.test
CONF
}

# bsmtp_arg_after FLAG prints the argument that follows FLAG in the first
# recorded bsmtp call.
bsmtp_arg_after() {
  awk -v f="$1" '/^BODY$/ { exit } p { print; exit } $0 == f { p = 1 }' "$BSMTP_LOG"
}

# run_lines prints the "run job=..." lines the stub received, in order.
run_lines() {
  grep '^run job=' "$BCONSOLE_LOG"
}

@test "missing arguments print usage and exit 2" {
  sequence
  run "$BACKUP" server01
  [ "$status" -eq 2 ]
  [[ "$output" == *Usage:* ]]
  [ ! -s "$BCONSOLE_LOG" ]
}

@test "unknown option exits 2" {
  sequence
  run "$BACKUP" server01 full --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *Usage:* ]]
}

@test "unknown backup type exits 2 without contacting the director" {
  sequence status-dir-ok.txt
  run "$BACKUP" server01 weekly
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid backup type"* ]]
  [ ! -s "$BCONSOLE_LOG" ]
}

@test "director down exits 3 and queues no job" {
  sequence status-dir-refused.txt
  run "$BACKUP" server01 full
  [ "$status" -eq 3 ]
  [ -z "$(run_lines)" ]
  grep -q 'ERROR: .*Director' "$WORK/backup.log"
}

@test "job T and verify T exit 0 with one backup run and one verify run" {
  sequence status-dir-ok.txt run-queued.txt list-jobid-T.txt run-queued.txt list-jobid-T.txt
  run "$BACKUP" server01 full
  [ "$status" -eq 0 ]
  [ "$(run_lines)" = 'run job="server01-full" yes
run job="Verify-server01" yes' ]
  [ "$(grep -c '^run job="Verify-server01" yes$' "$BCONSOLE_LOG")" -eq 1 ]
}

@test "the job name is built from client and level" {
  sequence status-dir-ok.txt run-queued.txt list-jobid-T.txt
  run "$BACKUP" server01 incremental --no-verify
  [ "$status" -eq 0 ]
  [ "$(run_lines)" = 'run job="server01-incremental" yes' ]
}

@test "job ending in f exits 1 and does not verify" {
  sequence status-dir-ok.txt run-queued.txt list-jobid-f.txt
  run "$BACKUP" server01 full
  [ "$status" -eq 1 ]
  [ "$(run_lines)" = 'run job="server01-full" yes' ]
  grep -q 'ERROR: .*status f' "$WORK/backup.log"
}

@test "job that is not queued exits 1" {
  sequence status-dir-ok.txt status-dir-refused.txt
  run "$BACKUP" server01 full
  [ "$status" -eq 1 ]
}

@test "verify ending in f exits 4" {
  sequence status-dir-ok.txt run-queued.txt list-jobid-T.txt run-queued.txt list-jobid-f.txt
  run "$BACKUP" server01 differential
  [ "$status" -eq 4 ]
  [ "$(run_lines)" = 'run job="server01-differential" yes
run job="Verify-server01" yes' ]
}

@test "--no-verify skips the verify job" {
  sequence status-dir-ok.txt run-queued.txt list-jobid-T.txt
  run "$BACKUP" --no-verify server01 full
  [ "$status" -eq 0 ]
  [ "$(run_lines)" = 'run job="server01-full" yes' ]
}

@test "low free space on VOLUME_DIR logs a WARNING and still runs" {
  echo 'MIN_FREE_KB=999999999999' >> "$BACKUP_CONF"
  sequence status-dir-ok.txt run-queued.txt list-jobid-T.txt
  run "$BACKUP" server01 full --no-verify
  [ "$status" -eq 0 ]
  grep -q 'WARNING: .*free space' "$WORK/backup.log"
}

@test "enough free space logs no WARNING" {
  sequence status-dir-ok.txt run-queued.txt list-jobid-T.txt
  run "$BACKUP" server01 full --no-verify
  [ "$status" -eq 0 ]
  run grep -c 'WARNING' "$WORK/backup.log"
  [ "$output" = "0" ]
}

@test "no temporary bconsole scripts are left in /tmp" {
  sequence status-dir-ok.txt run-queued.txt list-jobid-T.txt run-queued.txt list-jobid-T.txt
  run "$BACKUP" server01 full
  [ "$status" -eq 0 ]
  [ -z "$(ls /tmp/backup_server01_* /tmp/verify_server01.* 2>/dev/null)" ]
}

@test "with SMTP_HOST set, a successful run mails the summary through bsmtp" {
  with_smtp
  sequence status-dir-ok.txt run-queued.txt list-jobid-T.txt
  run "$BACKUP" server01 incremental --no-verify
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ARGS$' "$BSMTP_LOG")" -eq 1 ]
  [ "$(bsmtp_arg_after -h)" = "mailhost.test" ]
  subject=$(bsmtp_arg_after -s)
  echo "subject=$subject"
  [[ "$subject" == *OK* ]]
  [[ "$subject" == *server01* ]]
  [[ "$subject" == *incremental* ]]
  # The recipient is the last argument.
  [ "$(sed -n '/^BODY$/{x;p;q;};h' "$BSMTP_LOG")" = "ops@example.test" ]
  sed -n '/^BODY$/,/^END$/p' "$BSMTP_LOG" | grep -q 'Backup completed for server01'
  sed -n '/^BODY$/,/^END$/p' "$BSMTP_LOG" | grep -q 'Queued server01-incremental as JobId 42'
}

@test "with SMTP_HOST set, a failed job mails a FAILED summary" {
  with_smtp
  sequence status-dir-ok.txt run-queued.txt list-jobid-f.txt
  run "$BACKUP" server01 full
  [ "$status" -eq 1 ]
  [ "$(grep -c '^ARGS$' "$BSMTP_LOG")" -eq 1 ]
  subject=$(bsmtp_arg_after -s)
  [[ "$subject" == *FAILED* ]]
  [[ "$subject" == *server01* ]]
  [[ "$subject" == *full* ]]
  sed -n '/^BODY$/,/^END$/p' "$BSMTP_LOG" | grep -q 'ERROR: .*status f'
}

@test "usage errors send no mail even with SMTP_HOST set" {
  with_smtp
  sequence
  run "$BACKUP" server01 weekly
  [ "$status" -eq 2 ]
  [ ! -e "$BSMTP_LOG" ]
}

@test "without SMTP_HOST, bsmtp is not invoked" {
  sequence status-dir-ok.txt run-queued.txt list-jobid-T.txt
  run "$BACKUP" server01 incremental --no-verify
  [ "$status" -eq 0 ]
  [ ! -e "$BSMTP_LOG" ]
}
