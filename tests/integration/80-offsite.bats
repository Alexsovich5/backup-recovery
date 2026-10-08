#!/usr/bin/env bats
# BackupCatalog dumps the catalog, backs the dump up and, in its
# RunAfterJob step, copies volumes, bootstrap files and the dump to the
# offsite rsync daemon, which requires the "bacula" login. The copy is
# checked through the rsync daemon and through the read-only offsite
# volume mounted at /offsite.

load helpers

OFFSITE=rsync://bacula@offsite/bacula

@test "run job=BackupCatalog ends in T" {
  run run_and_wait BackupCatalog
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the offsite volumes/ directory holds a Full-* volume" {
  run offsite_rsync --list-only "$OFFSITE/volumes/"
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE ' Full-[0-9]+$'
}

@test "the offsite bsr/ directory holds server01-fd.bsr and BackupCatalog.bsr" {
  run offsite_rsync --list-only "$OFFSITE/bsr/"
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE ' server01-fd\.bsr$'
  echo "$output" | grep -qE ' BackupCatalog\.bsr$'
}

@test "the offsite db/ directory holds bacula.sql" {
  run offsite_rsync --list-only "$OFFSITE/db/"
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE ' bacula\.sql$'
}

@test "the offsite module refuses anonymous and wrong-password access" {
  run rsync --list-only rsync://offsite/bacula/db/ < /dev/null
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" != *bacula.sql* ]]
  printf 'wrong-password\n' > "$BATS_TMPDIR/t80-wrong"
  chmod 600 "$BATS_TMPDIR/t80-wrong"
  run rsync --password-file="$BATS_TMPDIR/t80-wrong" --list-only "$OFFSITE/db/"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" != *bacula.sql* ]]
  echo tampered > "$BATS_TMPDIR/t80-file"
  run rsync --password-file="$BATS_TMPDIR/t80-wrong" "$BATS_TMPDIR/t80-file" "$OFFSITE/db/bacula.sql"
  [ "$status" -ne 0 ]
  [ "$(head -c 8 /offsite/db/bacula.sql)" != "tampered" ]
}

@test "/offsite/db/bacula.sql is not empty" {
  [ -s /offsite/db/bacula.sql ]
}
