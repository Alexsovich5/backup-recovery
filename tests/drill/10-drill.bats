#!/usr/bin/env bats
# Disaster-recovery drill, run in the drill service while dr-client is up.
# drill-run.sh makes a manifest of server01's data, then dr-drill.sh
# recovers the catalog dump from the offsite volumes with bextract, loads
# it into the scratch catalog bacula_drill and restores server01's
# encrypted data through scratch daemons to drill-fd on dr-client, the only
# holder of the master key (its keysafe volume stands in for an offline key
# safe). tests/integration/90-drill-setup.bats made the backup and the
# offsite copy before this suite runs.
#
# This service has no Director, Storage Daemon or File Daemon password and
# no Docker CLI; it reaches dr-client through drill-fd's port only.

DRILL_OUT="$BATS_TMPDIR/drill.out"
SRC=/src

@test "drill-run.sh exits 0 using only /offsite, the client data and drill-fd on dr-client" {
  rm -f "$DRILL_OUT"
  rc=0
  "$SRC/scripts/drill-run.sh" > "$DRILL_OUT" 2>&1 || rc=$?
  cat "$DRILL_OUT"
  [ "$rc" -eq 0 ]
}

@test "the drill recovered the dump, found catalog jobs and verified every file" {
  cat "$DRILL_OUT"
  grep -qx 'catalog dump recovered from volume: OK' "$DRILL_OUT"
  jobs=$(sed -n 's/^catalog jobs: \([0-9][0-9]*\)$/\1/p' "$DRILL_OUT")
  [[ "$jobs" =~ ^[0-9]+$ ]]
  [ "$jobs" -ge 1 ]
  expected=$(find /clientdata/server01 -type f | wc -l)
  [ "$expected" -gt 0 ]
  grep -qx "files verified: $expected" "$DRILL_OUT"
}

@test "the drill restored through drill-fd and left no restore behind" {
  grep -q 'restoring server01-fd to drill-fd on dr-client' "$DRILL_OUT"
  [ -d /drill-restores ]
  [ -z "$(ls -A /drill-restores)" ]
}

@test "afterwards bacula_drill is gone and nothing listens on 9201-9203" {
  cnf="$BATS_TMPDIR/drill.cnf"
  (umask 077; printf '[client]\nuser=%s\npassword=%s\n' "$DB_USER" "$DB_PASSWORD" > "$cnf")
  run mysql --defaults-extra-file="$cnf" -h "$DB_HOST" -N -B -e 'SHOW DATABASES'
  rm -f "$cnf"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -cx bacula_drill)" -eq 0 ]
  # "! cmd" does not fail a bats test, so test each port explicitly.
  for port in 9201 9202 9203; do
    if (exec 3<> "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      echo "port $port still accepts connections"
      false
    fi
  done
}

@test "the drill account can touch bacula_drill only, not the live catalog" {
  cnf="$BATS_TMPDIR/drill.cnf"
  (umask 077; printf '[client]\nuser=%s\npassword=%s\n' "$DB_USER" "$DB_PASSWORD" > "$cnf")
  run mysql --defaults-extra-file="$cnf" -h "$DB_HOST" -N -B bacula -e 'SELECT COUNT(*) FROM Job'
  echo "$output"
  [ "$status" -ne 0 ]
  run mysql --defaults-extra-file="$cnf" -h "$DB_HOST" -N -B -e 'SHOW DATABASES'
  rm -f "$cnf"
  [ "$(echo "$output" | grep -cx bacula)" -eq 0 ]
}

@test "this service holds only its own secret file and no other service's password" {
  [ "$(ls /run/secrets)" = "drill" ]
  [ "$(stat -c %a /run/secrets/drill | cut -c2-3)" = "00" ]
  names=$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' /run/secrets/drill | sort | tr '\n' ' ')
  [ "$names" = "DB_PASSWORD DRFD_PASSWORD " ]
  for v in DIR_PASSWORD FD_PASSWORD SD_PASSWORD OFFSITE_PASSWORD DRILL_DB_PASSWORD; do
    [ -z "${!v}" ]
  done
  [ ! -e /etc/bacula/offsite.passwd ]
}

@test "this service holds no private key" {
  for d in /etc /root /src /tmp /var /keys /keysafe /masterpub /drill-restores /offsite /clientdata; do
    [ -e "$d" ] || continue
    run bash -c "grep -rlE -- '^-----BEGIN [A-Z ]*PRIVATE KEY-----' $d 2>/dev/null"
    echo "$d: $output"
    [ "$status" -eq 1 ]
  done
}
