#!/usr/bin/env bats
# Renders the Bacula templates with config/bacula.env.example and
# config/passwords.env.example into build/
# and checks them with the daemons' own parsers plus static rules.

ROOT="$BATS_TEST_DIRNAME/../.."
BUILD="$ROOT/build"

render_all() {
  (
    set -e -a
    . "$ROOT/config/bacula.env.example"
    . "$ROOT/config/passwords.env.example"
    set +a
    for f in bacula-dir bacula-sd bacula-fd bacula-fd-director bconsole; do
      "$ROOT/scripts/render-config.sh" "$ROOT/config/$f.conf" "$BUILD/$f.conf"
    done
  )
}

setup() {
  mkdir -p "$BUILD"
  render_all
  # 5.2.6 bacula-fd -t loads the PKI files named in bacula-fd.conf.
  if [ ! -f "$BUILD/keys/server01.pem" ]; then
    rm -rf "$BUILD/keys"
    "$ROOT/scripts/gen-keys.sh" "$BUILD/keys" server01 > /dev/null
  fi
}

# Prints the body of every "Job {" block, one block per paragraph,
# each prefixed with a line "== <Name>".
job_blocks() {
  awk '
    /^[ \t]*#/ { next }
    /^Job[ \t]*\{/ { inblk = 1; body = ""; name = ""; next }
    inblk && /^\}/ { print "== " name; printf "%s", body; print ""; inblk = 0; next }
    inblk {
      body = body $0 "\n"
      if ($0 ~ /^[ \t]*Name[ \t]*=/) {
        n = $0; sub(/^[^=]*=[ \t]*/, "", n); gsub(/"/, "", n); name = n
      }
    }
  ' "$BUILD/bacula-dir.conf"
}

@test "rendering all templates with the example env succeeds" {
  for f in bacula-dir bacula-sd bacula-fd bacula-fd-director bconsole; do
    [ -s "$BUILD/$f.conf" ]
  done
}

@test "bacula-sd -t accepts the rendered sd config" {
  run bacula-sd -t -c "$BUILD/bacula-sd.conf"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "bacula-fd -t accepts the rendered fd config" {
  run bacula-fd -t -c "$BUILD/bacula-fd.conf"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "bacula-fd -t accepts the rendered director-host fd config" {
  run bacula-fd -t -c "$BUILD/bacula-fd-director.conf"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "server01-fd signs and encrypts with its keypair and the master key" {
  key_dir=$(. "$ROOT/config/bacula.env.example"; echo "$KEY_DIR")
  run awk '/^FileDaemon[ \t]*\{/{b=1} b&&/^\}/{b=0} b' "$BUILD/bacula-fd.conf"
  echo "$output"
  echo "$output" | grep -qE 'Name[[:space:]]*=[[:space:]]*server01-fd'
  echo "$output" | grep -qE 'PKI Signatures[[:space:]]*=[[:space:]]*yes'
  echo "$output" | grep -qE 'PKI Encryption[[:space:]]*=[[:space:]]*yes'
  echo "$output" | grep -qE "PKI Keypair[[:space:]]*=[[:space:]]*\"?$key_dir/server01.pem\"?\$"
  echo "$output" | grep -qE "PKI Master Key[[:space:]]*=[[:space:]]*\"?$key_dir/master.cert\"?\$"
}

@test "plaintext-control backs up secret.txt from backup-fd uncompressed into Default" {
  run job_blocks
  blk=$(echo "$output" | awk '/^== /{p = ($0 == "== plaintext-control")} p')
  echo "$blk"
  [ -n "$blk" ]
  echo "$blk" | grep -qE 'Client[[:space:]]*=[[:space:]]*backup-fd'
  echo "$blk" | grep -qE 'Pool[[:space:]]*=[[:space:]]*Default'
  echo "$blk" | grep -qE 'FileSet[[:space:]]*=[[:space:]]*"?ControlFileSet"?'
  run grep -cE '^[[:space:]]*Schedule' <<< "$blk"
  [ "$output" = "0" ]
  fs=$(awk '/^FileSet[ \t]*\{/{b=1; blk=""} b{blk = blk $0 "\n"} b&&/^\}/{b=0; if (blk ~ /Name[ \t]*=[ \t]*"?ControlFileSet"?/) printf "%s", blk}' "$BUILD/bacula-dir.conf")
  echo "$fs"
  echo "$fs" | grep -qE 'File[[:space:]]*=[[:space:]]*/clientdata/server01/secret.txt'
  run grep -ciE 'compression' <<< "$fs"
  [ "$output" = "0" ]
}

@test "the director-host fd is backup-fd and has no PKI directives" {
  grep -qE '^[[:space:]]*Name[[:space:]]*=[[:space:]]*"?backup-fd"?[[:space:]]*$' "$BUILD/bacula-fd-director.conf"
  run grep -ciE '^[[:space:]]*PKI' "$BUILD/bacula-fd-director.conf"
  [ "$output" = "0" ]
}

@test "the Director defines Client backup-fd on the director host" {
  run awk '/^Client[ \t]*\{/{b=1; blk=""} b{blk = blk $0 "\n"} b&&/^\}/{b=0; if (blk ~ /Name[ \t]*=[ \t]*"?backup-fd"?/) printf "%s", blk}' "$BUILD/bacula-dir.conf"
  echo "$output"
  [ -n "$output" ]
  dir_host=$(. "$ROOT/config/bacula.env.example"; echo "$DIR_HOST")
  echo "$output" | grep -qE "Address[[:space:]]*=[[:space:]]*$dir_host\$"
  echo "$output" | grep -qE 'Catalog[[:space:]]*=[[:space:]]*MyCatalog'
}

@test "bconsole -t accepts the rendered console config" {
  run bconsole -t -c "$BUILD/bconsole.conf"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "no rendered file contains Password123 or 192.168." {
  run grep -l -e 'Password123' -e '192\.168\.' "$BUILD"/bacula-dir.conf "$BUILD"/bacula-sd.conf \
    "$BUILD"/bacula-fd.conf "$BUILD"/bconsole.conf
  [ "$status" -eq 1 ]
}

@test "no template contains a hard-coded password or private address" {
  run grep -l -e 'Password123' -e '192\.168\.' "$ROOT"/config/*.conf
  [ "$status" -eq 1 ]
}

@test "director is named backup-dir" {
  run grep -E '^[[:space:]]*Name[[:space:]]*=[[:space:]]*"?backup-dir"?[[:space:]]*$' "$BUILD/bacula-dir.conf"
  [ "$status" -eq 0 ]
}

@test "only server01-backup and BackupCatalog jobs carry a Schedule" {
  run job_blocks
  [ "$status" -eq 0 ]
  scheduled=$(echo "$output" | awk '/^== /{n=substr($0,4)} /^[ \t]*Schedule[ \t]*=/{print n}' | sort -u)
  echo "scheduled: $scheduled"
  [[ "$scheduled" == *server01-backup* ]]
  for n in $scheduled; do
    [ "$n" = "server01-backup" ] || [ "$n" = "BackupCatalog" ]
  done
}

@test "server01-backup uses WeeklyCycle and the three level pools" {
  run job_blocks
  blk=$(echo "$output" | awk '/^== /{p = ($0 == "== server01-backup")} p')
  echo "$blk"
  [[ "$blk" == *"Schedule = \"WeeklyCycle\""* || "$blk" == *"Schedule = WeeklyCycle"* ]]
  echo "$blk" | grep -qE 'Full Backup Pool[[:space:]]*=[[:space:]]*FullPool'
  echo "$blk" | grep -qE 'Differential Backup Pool[[:space:]]*=[[:space:]]*DifferentialPool'
  echo "$blk" | grep -qE 'Incremental Backup Pool[[:space:]]*=[[:space:]]*IncrementalPool'
}

@test "the JobDefs block has no Schedule" {
  run awk '/^JobDefs[ \t]*\{/{b=1} b&&/^\}/{b=0} b' "$BUILD/bacula-dir.conf"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'DefaultJob'
  run grep -cE '^[[:space:]]*Schedule[[:space:]]*=' <<< "$output"
  [ "$output" = "0" ]
}

@test "every Job block has a Pool or JobDefs line" {
  run job_blocks
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c '^== ')" -ge 6 ]
  missing=$(echo "$output" | awk '
    /^== / { if (n != "" && !ok) print n; n = substr($0, 4); ok = 0; next }
    /^[ \t]*(Pool|JobDefs)[ \t]*=/ { ok = 1 }
    END { if (n != "" && !ok) print n }')
  echo "missing: $missing"
  [ -z "$missing" ]
}

@test "Verify-server01 is VolumeToCatalog with Pool Default" {
  run job_blocks
  blk=$(echo "$output" | awk '/^== /{p = ($0 == "== Verify-server01")} p')
  echo "$blk" | grep -qE 'Level[[:space:]]*=[[:space:]]*VolumeToCatalog'
  echo "$blk" | grep -qE 'Pool[[:space:]]*=[[:space:]]*Default'
}

@test "pools carry their Label Format" {
  for p in Full Diff Incr Default; do
    grep -qE "Label Format[[:space:]]*=[[:space:]]*\"$p-\"" "$BUILD/bacula-dir.conf"
  done
}

@test "mail is sent through the SMTP host from the env file" {
  smtp=$(. "$ROOT/config/bacula.env.example"; echo "$SMTP_HOST")
  [ -n "$smtp" ]
  grep -qE "mailcommand = .*bsmtp -h $smtp " "$BUILD/bacula-dir.conf"
  run grep -c 'bsmtp -h localhost' "$BUILD/bacula-dir.conf"
  [ "$output" = "0" ]
}

@test "sd device FileStorage is a File device with LabelMedia" {
  run awk '/^Device[ \t]*\{/{b=1} b&&/^\}/{b=0} b' "$BUILD/bacula-sd.conf"
  echo "$output" | grep -qE 'Name[[:space:]]*=[[:space:]]*FileStorage'
  echo "$output" | grep -qE 'Media Type[[:space:]]*=[[:space:]]*File'
  echo "$output" | grep -qiE 'LabelMedia[[:space:]]*=[[:space:]]*yes'
}
