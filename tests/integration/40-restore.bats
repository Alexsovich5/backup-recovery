#!/usr/bin/env bats
# scripts/restore.sh against the live stack: an in-place restore of
# server01's data, a single-file restore into the shared /restores volume,
# and a restore to backup-fd, which holds no keypair and so must not be
# able to decrypt server01's data.

load helpers

DATA=/clientdata/server01
MANIFEST="$BATS_TMPDIR/t40-manifest"
MARKER=PLAINTEXT-MARKER-7f3a

setup() {
  export WAIT_INTERVAL WAIT_TIMEOUT
}

@test "in-place restore brings back a deleted directory with matching checksums" {
  run "$SRC/scripts/make-manifest.sh" "$DATA" "$MANIFEST"
  [ "$status" -eq 0 ]
  grep -q '  docs/' "$MANIFEST"
  run "$SRC/scripts/backup.sh" server01 full --no-verify
  echo "$output"
  [ "$status" -eq 0 ]

  rm -rf "$DATA/docs"
  [ ! -e "$DATA/docs" ]

  run "$SRC/scripts/restore.sh" --client server01 --where /
  echo "$output"
  [ "$status" -eq 0 ]

  [ -d "$DATA/docs" ]
  run bash -c "cd '$DATA' && md5sum -c '$MANIFEST'"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "single-file restore writes only that file and its checksum matches" {
  [ -s "$MANIFEST" ]
  rel=$(awk '$2 ~ /^docs\// { print $2; exit }' "$MANIFEST")
  [ -n "$rel" ]
  target=/restores/t40-file
  rm -rf "$target"

  run "$SRC/scripts/restore.sh" --client server01 --file "/srv/data/$rel" --where "$target"
  echo "$output"
  [ "$status" -eq 0 ]

  run find "$target/srv/data" -type f
  echo "$output"
  [ "$output" = "$target/srv/data/$rel" ]
  run bash -c "cd '$target/srv/data' && grep '  $rel\$' '$MANIFEST' | md5sum -c -"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "restore to backup-fd cannot decrypt server01 data" {
  rm -rf /tmp/t40-nokey
  before=$(last_jobid RestoreFiles)
  [[ "$before" =~ ^[0-9]+$ ]] || before=0

  run "$SRC/scripts/restore.sh" --client server01 --restore-client backup-fd \
    --file /srv/data/secret.txt --where /tmp/t40-nokey
  echo "$output"

  jobid=$(last_jobid RestoreFiles)
  [[ "$jobid" =~ ^[0-9]+$ ]]
  [ "$jobid" -gt "$before" ]
  run grep -E "JobId $jobid: .*(No private decryption keys|Missing private key)" /var/log/bacula/bacula.log
  echo "$output"
  [ "$status" -eq 0 ]

  if [ -e /tmp/t40-nokey/srv/data/secret.txt ]; then
    run grep -c "$MARKER" /tmp/t40-nokey/srv/data/secret.txt
    [ "$output" = "0" ]
  fi
}
