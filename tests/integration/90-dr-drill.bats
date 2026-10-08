#!/usr/bin/env bats
# Disaster-recovery drill: dr-drill.sh recovers the catalog dump from the
# offsite volumes with bextract, loads it into a scratch catalog and
# restores server01's encrypted data through scratch daemons to drill-fd
# on dr-client, the only holder of the master key (its keysafe volume
# stands in for an offline key safe). The suite makes its own backup and
# offsite copy first.

load helpers

DATA=/clientdata/server01
MANIFEST="$BATS_TMPDIR/t90-manifest"
DRILL_OUT="$BATS_TMPDIR/t90-drill.out"

setup() {
  export WAIT_INTERVAL WAIT_TIMEOUT DB_HOST DB_PASSWORD DIR_HOST DRFD_HOST DRFD_PASSWORD
}

# Steps that call wait_job avoid bats "run" (see 50-verify.bats).
@test "setup: manifest, incremental backup and offsite copy via BackupCatalog" {
  rm -f "$MANIFEST" "$DRILL_OUT"
  "$SRC/scripts/make-manifest.sh" "$DATA" "$MANIFEST"
  [ -s "$MANIFEST" ]

  "$SRC/scripts/backup.sh" server01 incremental --no-verify

  result=$(run_and_wait BackupCatalog)
  echo "BackupCatalog: $result"
  [ "${result#* }" = "T" ]
  [ -s /offsite/bsr/BackupCatalog.bsr ]
}

@test "dr-drill.sh exits 0 using only /offsite and drill-fd on dr-client" {
  [ -s "$MANIFEST" ]
  rc=0
  "$SRC/scripts/dr-drill.sh" --offsite /offsite --manifest "$MANIFEST" \
    > "$DRILL_OUT" 2>&1 || rc=$?
  cat "$DRILL_OUT"
  [ "$rc" -eq 0 ]
}

@test "the drill recovered the dump, found catalog jobs and verified every file" {
  cat "$DRILL_OUT"
  grep -qx 'catalog dump recovered from volume: OK' "$DRILL_OUT"
  jobs=$(sed -n 's/^catalog jobs: \([0-9][0-9]*\)$/\1/p' "$DRILL_OUT")
  [[ "$jobs" =~ ^[0-9]+$ ]]
  [ "$jobs" -ge 1 ]
  expected=$(grep -c . "$MANIFEST")
  grep -qx "files verified: $expected" "$DRILL_OUT"
}

@test "the drill restored through drill-fd and left no restore behind" {
  grep -q 'restoring server01-fd to drill-fd on dr-client' "$DRILL_OUT"
  [ -d /drill-restores ]
  [ -z "$(ls -A /drill-restores)" ]
}

@test "afterwards bacula_drill is gone and nothing listens on 9201-9203" {
  run mysql --defaults-extra-file=/etc/bacula/catalog.cnf -h "$DB_HOST" -N -B -e 'SHOW DATABASES'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *bacula* ]]
  [ "$(echo "$output" | grep -cx bacula_drill)" -eq 0 ]
  # "! cmd" does not fail a bats test, so test each port explicitly.
  for port in 9201 9202 9203; do
    if (exec 3<> "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      echo "port $port still accepts connections"
      false
    fi
  done
}
