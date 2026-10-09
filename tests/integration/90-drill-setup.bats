#!/usr/bin/env bats
# Prepares the disaster-recovery drill: a fresh backup of server01 and a
# BackupCatalog run, which leaves the catalog dump, the bootstrap file and
# the volumes in the offsite copy. The drill runs afterwards in the drill
# service (tests/drill/10-drill.bats), which can see /offsite and the
# client data read-only but has no Director password.

load helpers

# Steps that call wait_job avoid bats "run" (see 50-verify.bats).
@test "an incremental backup and an offsite copy via BackupCatalog" {
  "$SRC/scripts/backup.sh" server01 incremental --no-verify

  result=$(run_and_wait BackupCatalog)
  echo "BackupCatalog: $result"
  [ "${result#* }" = "T" ]
  [ -s /offsite/bsr/BackupCatalog.bsr ]
}
