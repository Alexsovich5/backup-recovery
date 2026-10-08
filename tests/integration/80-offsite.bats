#!/usr/bin/env bats
# BackupCatalog dumps the catalog, backs the dump up and, in its
# RunAfterJob step, copies volumes, bootstrap files and the dump to the
# offsite rsync daemon. The copy is checked through the rsync daemon and
# through the read-only offsite volume mounted at /offsite.

load helpers

OFFSITE=rsync://offsite/bacula

@test "run job=BackupCatalog ends in T" {
  run run_and_wait BackupCatalog
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the offsite volumes/ directory holds a Full-* volume" {
  run rsync --list-only "$OFFSITE/volumes/"
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE ' Full-[0-9]+$'
}

@test "the offsite bsr/ directory holds server01-fd.bsr and BackupCatalog.bsr" {
  run rsync --list-only "$OFFSITE/bsr/"
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE ' server01-fd\.bsr$'
  echo "$output" | grep -qE ' BackupCatalog\.bsr$'
}

@test "the offsite db/ directory holds bacula.sql" {
  run rsync --list-only "$OFFSITE/db/"
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE ' bacula\.sql$'
}

@test "/offsite/db/bacula.sql is not empty" {
  [ -s /offsite/db/bacula.sql ]
}
