#!/usr/bin/env bats
# Tests for scripts/offsite-sync.sh, run against the rsync stub.

SYNC="$BATS_TEST_DIRNAME/../../scripts/offsite-sync.sh"

setup() {
  WORK="$BATS_TMPDIR/offsite-sync.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK/lib/volumes"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  export RSYNC_LOG="$WORK/rsync.log"
  export BACKUP_CONF="$WORK/none.conf"
  export LOG_FILE="$WORK/sync.log"
  export BACULA_WORKDIR="$WORK/lib"
  export VOLUME_DIR="$WORK/lib/volumes"
  export OFFSITE_PASSWORD_FILE="$WORK/offsite.passwd"
  (umask 077; echo 'S3NTINEL-pw' > "$OFFSITE_PASSWORD_FILE")
  unset OFFSITE_DEST RSYNC_STUB_EXIT
  : > "$RSYNC_LOG"
  : > "$WORK/lib/volumes/Full-0001"
  : > "$WORK/lib/BackupCatalog.bsr"
  : > "$WORK/lib/server01-fd.bsr"
  echo "-- dump" > "$WORK/lib/bacula.sql"
}

teardown() {
  rm -rf "$WORK"
}

@test "copies volumes, bootstrap files and the catalog dump with rsync -a" {
  run "$SYNC"
  echo "$output"
  [ "$status" -eq 0 ]
  cat "$RSYNC_LOG"
  [ "$(grep -c . "$RSYNC_LOG")" -eq 3 ]
  pw="--password-file=$WORK/offsite.passwd"
  [ "$(sed -n 1p "$RSYNC_LOG")" = "-a $pw $WORK/lib/volumes/ rsync://bacula@offsite/bacula/volumes/" ]
  [ "$(sed -n 2p "$RSYNC_LOG")" = "-a $pw $WORK/lib/BackupCatalog.bsr $WORK/lib/server01-fd.bsr rsync://bacula@offsite/bacula/bsr/" ]
  [ "$(sed -n 3p "$RSYNC_LOG")" = "-a $pw $WORK/lib/bacula.sql rsync://bacula@offsite/bacula/db/" ]
}

@test "the rsync password is read from a file and never appears in arguments, output or log" {
  run "$SYNC"
  [ "$status" -eq 0 ]
  export RSYNC_STUB_EXIT=5
  run "$SYNC"
  echo "$output"
  [ "$status" -eq 5 ]
  [ "$(grep -c 'S3NTINEL-pw' "$RSYNC_LOG")" -eq 0 ]
  [ "$(grep -c 'S3NTINEL-pw' "$LOG_FILE")" -eq 0 ]
  [[ "$output" != *S3NTINEL-pw* ]]
}

@test "a missing or unreadable password file exits 2 without calling rsync" {
  export OFFSITE_PASSWORD_FILE="$WORK/missing.passwd"
  run "$SYNC"
  echo "$output"
  [ "$status" -eq 2 ]
  [ ! -s "$RSYNC_LOG" ]
}

@test "--dest overrides the default destination" {
  run "$SYNC" --dest rsync://dr.example/vault
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$RSYNC_LOG")" -eq 3 ]
  [ "$(grep -c ' rsync://dr.example/vault/\(volumes\|bsr\|db\)/$' "$RSYNC_LOG")" -eq 3 ]
  ! grep -q 'offsite/bacula' "$RSYNC_LOG"
}

@test "a non-zero rsync exit is the script's exit and stops the sync" {
  export RSYNC_STUB_EXIT=23
  run "$SYNC"
  echo "$output"
  [ "$status" -eq 23 ]
  [ "$(grep -c . "$RSYNC_LOG")" -eq 1 ]
  grep -q 'ERROR: .*rsync.*23' "$LOG_FILE"
}

@test "unknown arguments and a missing --dest value exit 2" {
  run "$SYNC" --bogus
  [ "$status" -eq 2 ]
  run "$SYNC" --dest
  [ "$status" -eq 2 ]
  [ ! -s "$RSYNC_LOG" ]
}
