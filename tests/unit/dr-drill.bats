#!/usr/bin/env bats
# Tests for scripts/dr-drill.sh, run against the bextract, mysql, Bacula
# daemon and bconsole stubs. drill-fd itself runs on the recovery host
# (dr-client), so the drill starts only drill-sd and drill-dir here. The restore step goes through the real
# restore.sh (driven by the bconsole stub) or, where restored files are
# needed, through tests/unit/stubs/restore.sh via $RESTORE_SH.

ROOT="$BATS_TEST_DIRNAME/../.."
DRILL="$ROOT/scripts/dr-drill.sh"

setup() {
  WORK="$BATS_TMPDIR/dr-drill.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK/offsite/volumes" "$WORK/offsite/bsr" "$WORK/offsite/db" \
    "$WORK/drillrestores" "$WORK/tmp" "$WORK/tree/srv/data/docs"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"

  echo "volume" > "$WORK/offsite/volumes/Full-0001"
  echo "volume" > "$WORK/offsite/volumes/Default-0001"
  echo 'Volume="Default-0001"' > "$WORK/offsite/bsr/BackupCatalog.bsr"
  echo "-- catalog dump" > "$WORK/offsite/db/bacula.sql"

  echo alpha > "$WORK/tree/srv/data/alpha.txt"
  echo runbook > "$WORK/tree/srv/data/docs/runbook.txt"
  (cd "$WORK/tree/srv/data" && md5sum alpha.txt docs/runbook.txt) > "$WORK/manifest"

  export BEXTRACT_LOG="$WORK/bextract.log"
  export BEXTRACT_STUB_SQL="$WORK/offsite/db/bacula.sql"
  export MYSQL_LOG="$WORK/mysql.log"
  export DAEMON_LOG="$WORK/daemon.log"
  export BCONSOLE_LOG="$WORK/bconsole.log"
  export BCONSOLE_CURSOR="$WORK/bconsole.cursor"
  export BCONSOLE_SEQUENCE="$WORK/bconsole.seq"
  export RESTORE_SH="$BATS_TEST_DIRNAME/stubs/restore.sh"
  export RESTORE_STUB_TREE="$WORK/tree"
  export RESTORE_STUB_ARGS="$WORK/restore.args"
  export DRILL_TMPDIR="$WORK/tmp"
  export BACKUP_CONF="$WORK/none.conf"
  export LOG_FILE="$WORK/drill.log"
  export DB_HOST=catalog.test DB_PASSWORD=test-db-password
  export DRILL_SD_HOST=drill.test DRFD_HOST=dr-client.test DRFD_PASSWORD=test-drfd-password
  export WAIT_INTERVAL=0 DRILL_START_TIMEOUT=3
  unset BEXTRACT_STUB_EXIT MYSQL_STUB_EXIT MYSQL_STUB_JOBS RESTORE_STUB_EXIT
  : > "$BEXTRACT_LOG"
  : > "$MYSQL_LOG"
  : > "$DAEMON_LOG"
  echo status-dir-ok.txt > "$BCONSOLE_SEQUENCE"
}

teardown() {
  rm -rf "$WORK"
}

drill() {
  run "$DRILL" --offsite "$WORK/offsite" --manifest "$WORK/manifest" \
    --restore-dir "$WORK/drillrestores" "$@"
  echo "$output"
}

# The drill daemons that were started have all been stopped.
assert_daemons_stopped() {
  cat "$DAEMON_LOG"
  for d in $(awk '$1 == "start" { print $2 }' "$DAEMON_LOG"); do
    grep -qx "stop $d" "$DAEMON_LOG"
  done
}

# The last mysql call dropped the scratch catalog.
assert_scratch_db_dropped() {
  cat "$MYSQL_LOG"
  tail -n 1 "$MYSQL_LOG" | grep -q 'DROP DATABASE IF EXISTS bacula_drill'
}

assert_scratch_dir_removed() {
  [ -z "$(ls -A "$WORK/tmp")" ]
  [ -z "$(ls -A "$WORK/drillrestores")" ]
}

@test "a passing drill prints its checks, exits 0 and cleans up" {
  drill
  [ "$status" -eq 0 ]
  [[ "$output" == *"catalog dump recovered from volume: OK"* ]]
  [[ "$output" == *"catalog jobs: 3"* ]]
  [[ "$output" == *"files verified: 2"* ]]
  [ "$(grep -c '^start ' "$DAEMON_LOG")" -eq 2 ]
  assert_daemons_stopped
  assert_scratch_db_dropped
  assert_scratch_dir_removed
}

@test "bextract reads the offsite BackupCatalog.bsr through the drill SD config" {
  drill
  [ "$status" -eq 0 ]
  cat "$BEXTRACT_LOG"
  grep -qE -- "-b $WORK/offsite/bsr/BackupCatalog.bsr " "$BEXTRACT_LOG"
  grep -qE -- "-c $WORK/tmp/[^ ]+/bacula-sd-drill.conf " "$BEXTRACT_LOG"
  grep -qE ' FileStorage ' "$BEXTRACT_LOG"
}

@test "the dump is loaded into bacula_drill and server01-fd backups are counted" {
  drill
  [ "$status" -eq 0 ]
  cat "$MYSQL_LOG"
  grep -q 'DROP DATABASE IF EXISTS bacula_drill; CREATE DATABASE bacula_drill' "$MYSQL_LOG"
  grep -qE -- '-h catalog\.test .*bacula_drill$' "$MYSQL_LOG"
  grep 'COUNT(' "$MYSQL_LOG" | grep -q "server01-fd"
  grep 'COUNT(' "$MYSQL_LOG" | grep -q "Type='B'"
  grep 'COUNT(' "$MYSQL_LOG" | grep -q "JobStatus='T'"
  [ "$(grep -c "test-db-password" "$MYSQL_LOG")" -eq 0 ]
}

@test "--db-host overrides the catalog host" {
  drill --db-host other.test
  [ "$status" -eq 0 ]
  grep -q -- '-h other\.test' "$MYSQL_LOG"
  [ "$(grep -c -- '-h catalog\.test' "$MYSQL_LOG")" -eq 0 ]
}

@test "the drill starts only drill-sd and drill-dir, on the rendered drill configs" {
  drill
  [ "$status" -eq 0 ]
  grep -qE "^start bacula-sd -f -c $WORK/tmp/[^ ]+/bacula-sd-drill.conf$" "$DAEMON_LOG"
  grep -qE "^start bacula-dir -f -c $WORK/tmp/[^ ]+/bacula-dir-drill.conf$" "$DAEMON_LOG"
  [ "$(grep -c '^start bacula-fd' "$DAEMON_LOG")" -eq 0 ]
}

@test "the restore goes from server01 to drill-fd under a fresh directory in --restore-dir" {
  drill
  [ "$status" -eq 0 ]
  cat "$RESTORE_STUB_ARGS"
  grep -qE "^--client server01-fd --restore-client drill-fd --where $WORK/drillrestores/drill\.[^ /]+$" "$RESTORE_STUB_ARGS"
}

@test "drill-dir reaches drill-fd on the recovery host and handles no key material" {
  export DRILL_KEEP_CONF="$WORK/kept"
  # Copy the rendered configs out before cleanup removes them.
  export RESTORE_SH="$WORK/restore-copy.sh"
  cat > "$RESTORE_SH" <<'SH'
#!/bin/bash
cp "$BCONSOLE_CONF" "$(dirname "$BCONSOLE_CONF")"/*.conf "$DRILL_KEEP_CONF"/ 2>/dev/null
exec "$BATS_TEST_DIRNAME/stubs/restore.sh" "$@"
SH
  chmod +x "$RESTORE_SH"
  export BATS_TEST_DIRNAME
  mkdir -p "$DRILL_KEEP_CONF"
  drill
  [ "$status" -eq 0 ]
  ls "$DRILL_KEEP_CONF"
  [ ! -e "$DRILL_KEEP_CONF/bacula-fd-drill.conf" ]
  run awk '/^Client[ \t]*\{/{b=1; blk=""} b{blk = blk $0 "\n"} b&&/^\}/{b=0; if (blk ~ /Name[ \t]*=[ \t]*drill-fd/) printf "%s", blk}' "$DRILL_KEEP_CONF/bacula-dir-drill.conf"
  echo "$output"
  echo "$output" | grep -qE 'Address[[:space:]]*=[[:space:]]*dr-client\.test$'
  echo "$output" | grep -qE 'Password[[:space:]]*=[[:space:]]*"test-drfd-password"'
  grep -qE 'Address[[:space:]]*=[[:space:]]*drill\.test$' "$DRILL_KEEP_CONF/bacula-dir-drill.conf"
  run grep -rlE 'PRIVATE KEY|master\.(key|pem)' "$DRILL_KEEP_CONF"
  [ "$status" -eq 1 ]
}

@test "drill-dir uses the catalog account given in DB_USER" {
  export DB_USER=drilluser
  export RESTORE_SH="$WORK/restore-copy.sh"
  export DRILL_KEEP_CONF="$WORK/kept"
  cat > "$RESTORE_SH" <<'SH'
#!/bin/bash
cp "$(dirname "$BCONSOLE_CONF")"/bacula-dir-drill.conf "$DRILL_KEEP_CONF"/
exec "$BATS_TEST_DIRNAME/stubs/restore.sh" "$@"
SH
  chmod +x "$RESTORE_SH"
  export BATS_TEST_DIRNAME
  mkdir -p "$DRILL_KEEP_CONF"
  drill
  [ "$status" -eq 0 ]
  grep -qE 'DB User = "drilluser"' "$DRILL_KEEP_CONF/bacula-dir-drill.conf"
}

@test "the drill takes its passwords from the environment, not from config/bacula.env" {
  unset DB_PASSWORD
  drill
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"DB_PASSWORD is not set"* ]]
}

@test "a restored symlink that points outside the restore directory fails the drill" {
  mkdir -p "$WORK/outside"
  echo runbook > "$WORK/outside/runbook.txt"
  rm -rf "$WORK/tree/srv/data/docs"
  ln -s "$WORK/outside" "$WORK/tree/srv/data/docs"
  drill
  [ "$status" -eq 1 ]
  [[ "$output" == *symlink* ]]
  [[ "$output" != *"files verified"* ]]
  assert_daemons_stopped
  assert_scratch_db_dropped
  assert_scratch_dir_removed
  [ -f "$WORK/outside/runbook.txt" ]
}

@test "a restored symlink in place of a manifest file fails the drill" {
  echo alpha > "$WORK/outside-alpha"
  rm -f "$WORK/tree/srv/data/alpha.txt"
  ln -s "$WORK/outside-alpha" "$WORK/tree/srv/data/alpha.txt"
  drill
  [ "$status" -eq 1 ]
  [[ "$output" == *symlink* ]]
}

@test "a symlinked srv component of the restore fails the drill" {
  mkdir -p "$WORK/outside-srv"
  cp -a "$WORK/tree/srv/data" "$WORK/outside-srv/data"
  rm -rf "$WORK/tree/srv"
  ln -s "$WORK/outside-srv" "$WORK/tree/srv"
  drill
  [ "$status" -eq 1 ]
  [[ "$output" == *symlink* ]]
}

@test "--keys is no longer accepted: the drill host takes no key material" {
  mkdir -p "$WORK/keys"
  drill --keys "$WORK/keys"
  [ "$status" -eq 2 ]
  [ ! -s "$BEXTRACT_LOG" ]
}

@test "a manifest path leaving the restore directory exits 2 before anything runs" {
  printf '%s  %s\n' 0123456789abcdef0123456789abcdef ../../../etc/passwd >> "$WORK/manifest"
  drill
  [ "$status" -eq 2 ]
  [ ! -s "$BEXTRACT_LOG" ]
  [ ! -s "$MYSQL_LOG" ]
  [ ! -s "$DAEMON_LOG" ]
}

@test "the catalog password never appears in arguments, output or log, even on failure" {
  export DB_PASSWORD='S3NTINEL-pw'
  export MYSQL_STUB_EXIT=1
  drill
  [ "$status" -eq 1 ]
  [[ "$output" != *S3NTINEL-pw* ]]
  [ "$(grep -c 'S3NTINEL-pw' "$MYSQL_LOG")" -eq 0 ]
  [ "$(grep -c 'S3NTINEL-pw' "$LOG_FILE")" -eq 0 ]
}

@test "missing arguments exit 2" {
  run "$DRILL"
  [ "$status" -eq 2 ]
  run "$DRILL" --offsite "$WORK/offsite" --restore-dir "$WORK/drillrestores"
  [ "$status" -eq 2 ]
  run "$DRILL" --manifest "$WORK/manifest" --restore-dir "$WORK/drillrestores"
  [ "$status" -eq 2 ]
  run "$DRILL" --offsite "$WORK/offsite" --manifest "$WORK/manifest" --restore-dir "$WORK/nope"
  [ "$status" -eq 2 ]
  run "$DRILL" --offsite "$WORK/offsite" --manifest "$WORK/manifest" \
    --restore-dir "$WORK/drillrestores" --bogus
  [ "$status" -eq 2 ]
  [ ! -s "$BEXTRACT_LOG" ]
  [ ! -s "$DAEMON_LOG" ]
}

@test "a bextract failure exits 1 and still drops the scratch catalog" {
  export BEXTRACT_STUB_EXIT=1
  drill
  [ "$status" -eq 1 ]
  [[ "$output" != *"recovered from volume: OK"* ]]
  [ ! -s "$DAEMON_LOG" ]
  assert_scratch_db_dropped
  assert_scratch_dir_removed
}

@test "a recovered dump that differs from the offsite db/bacula.sql exits 1" {
  echo "-- something else" > "$WORK/other.sql"
  export BEXTRACT_STUB_SQL="$WORK/other.sql"
  drill
  [ "$status" -eq 1 ]
  [[ "$output" != *"recovered from volume: OK"* ]]
  [ "$(grep -c 'CREATE DATABASE' "$MYSQL_LOG")" -eq 0 ]
  [ ! -s "$DAEMON_LOG" ]
  assert_scratch_db_dropped
  assert_scratch_dir_removed
}

@test "an empty Job table exits 1 before any daemon starts" {
  export MYSQL_STUB_JOBS=0
  drill
  [ "$status" -eq 1 ]
  [[ "$output" == *"catalog jobs: 0"* ]]
  [ ! -s "$DAEMON_LOG" ]
  assert_scratch_db_dropped
  assert_scratch_dir_removed
}

@test "a restore that ends with status f exits 1 and stops the daemons" {
  unset RESTORE_SH
  printf '%s\n' status-dir-ok.txt status-dir-ok.txt restore-queued.txt list-jobid-f.txt \
    > "$BCONSOLE_SEQUENCE"
  drill
  [ "$status" -eq 1 ]
  cat "$BCONSOLE_LOG"
  grep -qE "^restore client=server01-fd restoreclient=drill-fd where=$WORK/drillrestores/drill\.[^ /]+ select current all done yes$" "$BCONSOLE_LOG"
  [[ "$output" != *"files verified"* ]]
  [ "$(grep -c '^start ' "$DAEMON_LOG")" -eq 2 ]
  assert_daemons_stopped
  assert_scratch_db_dropped
  assert_scratch_dir_removed
}

@test "a checksum mismatch exits 1, names the file and stops the daemons" {
  echo tampered > "$WORK/tree/srv/data/docs/runbook.txt"
  drill
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/runbook.txt: FAILED"* ]]
  [[ "$output" != *"files verified"* ]]
  assert_daemons_stopped
  assert_scratch_db_dropped
  assert_scratch_dir_removed
}

@test "a drill Director that never answers exits 1 and stops the daemons" {
  : > "$BCONSOLE_SEQUENCE"
  export DRILL_START_TIMEOUT=1
  drill
  [ "$status" -eq 1 ]
  [ ! -e "$RESTORE_STUB_ARGS" ]
  [ "$(grep -c '^start ' "$DAEMON_LOG")" -eq 2 ]
  assert_daemons_stopped
  assert_scratch_db_dropped
  assert_scratch_dir_removed
}

@test "--root selects the restored directory that is checked" {
  mkdir -p "$WORK/tree/data/app"
  echo app > "$WORK/tree/data/app/app.conf"
  (cd "$WORK/tree/data/app" && md5sum app.conf) > "$WORK/manifest"
  drill --root /data/app
  [ "$status" -eq 0 ]
  [[ "$output" == *"files verified: 1"* ]]
}
