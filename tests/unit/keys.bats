#!/usr/bin/env bats
# keydir_check (scripts/lib/keys.sh) and the key-directory refusals of the
# server01 and dr-client entrypoints.

ROOT="$BATS_TEST_DIRNAME/../.."

setup() {
  WORK="$BATS_TMPDIR/keys.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK/real"
  . "$ROOT/scripts/lib/keys.sh"
  ME=$(id -u)
}

teardown() {
  rm -rf "$WORK"
}

populate() {
  echo key > "$1/master.key"
  echo pem > "$1/master.pem"
  echo cert > "$1/master.cert"
  chmod 0700 "$1"
  chmod 0400 "$1/master.key" "$1/master.pem"
  chmod 0444 "$1/master.cert"
}

@test "keydir_check accepts a private directory of regular files owned by an allowed uid" {
  populate "$WORK/real"
  run keydir_check "$WORK/real" "$ME" master.key master.pem master.cert
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "keydir_check accepts a directory that does not hold the files yet" {
  run keydir_check "$WORK/real" "$ME" master.key master.pem master.cert
  [ "$status" -eq 0 ]
}

@test "keydir_check refuses a directory that is a symlink" {
  populate "$WORK/real"
  ln -s "$WORK/real" "$WORK/link"
  run keydir_check "$WORK/link" "$ME" master.key master.pem master.cert
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *symlink* ]]
}

@test "keydir_check refuses a key file that is a symlink" {
  populate "$WORK/real"
  echo other > "$WORK/target"
  rm "$WORK/real/master.key"
  ln -s "$WORK/target" "$WORK/real/master.key"
  run keydir_check "$WORK/real" "$ME" master.key master.pem master.cert
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *symlink* ]]
}

@test "keydir_check refuses a dangling symlink in place of a key file" {
  populate "$WORK/real"
  rm "$WORK/real/master.cert"
  ln -s "$WORK/nowhere" "$WORK/real/master.cert"
  run keydir_check "$WORK/real" "$ME" master.key master.pem master.cert
  [ "$status" -ne 0 ]
}

@test "keydir_check refuses a directory owned by a uid that is not allowed" {
  populate "$WORK/real"
  run keydir_check "$WORK/real" "$((ME + 1))" master.key
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *owner* ]]
}

@test "keydir_check refuses a key file owned by a uid that is not allowed" {
  populate "$WORK/real"
  # The directory check passes for $ME; the file check must also run.
  mkdir "$WORK/other"
  chmod 0700 "$WORK/other"
  run keydir_check "$WORK/real" "$ME" master.key
  [ "$status" -eq 0 ]
  chown_target=$((ME + 1))
  if [ "$ME" -eq 0 ]; then
    chown "$chown_target" "$WORK/real/master.key"
    run keydir_check "$WORK/real" "$ME" master.key
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *owner* ]]
  fi
}

@test "keydir_check refuses a group- or world-writable directory" {
  populate "$WORK/real"
  chmod 0770 "$WORK/real"
  run keydir_check "$WORK/real" "$ME" master.key
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *writable* ]]
}

@test "keydir_check refuses a missing directory and one that is a file" {
  run keydir_check "$WORK/none" "$ME" master.key
  [ "$status" -ne 0 ]
  echo x > "$WORK/plain"
  run keydir_check "$WORK/plain" "$ME" master.key
  [ "$status" -ne 0 ]
}

# The entrypoints read the key directory from KEYSAFE_DIR / CLIENT_KEY_DIR
# so these tests can point them at a scratch directory; the refusal must
# come before anything is generated, copied or chowned.
@test "entrypoint-drclient.sh refuses a symlinked keysafe and touches nothing" {
  populate "$WORK/real"
  ln -s "$WORK/real" "$WORK/keysafe"
  run env KEYSAFE_DIR="$WORK/keysafe" "$ROOT/docker/entrypoint-drclient.sh" init
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *symlink* ]]
  [ "$(stat -c %a "$WORK/real")" = 700 ]
  [ "$(stat -c %a "$WORK/real/master.key")" = 400 ]
}

@test "entrypoint-drclient.sh refuses a symlinked master key file" {
  populate "$WORK/real"
  echo other > "$WORK/target"
  rm "$WORK/real/master.pem"
  ln -s "$WORK/target" "$WORK/real/master.pem"
  run env KEYSAFE_DIR="$WORK/real" "$ROOT/docker/entrypoint-drclient.sh" init
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *symlink* ]]
}

@test "entrypoint-drclient.sh refuses a keysafe with the wrong owner" {
  if [ "$ME" -ne 0 ]; then skip "needs root to chown"; fi
  populate "$WORK/real"
  chown 4242 "$WORK/real"
  run env KEYSAFE_DIR="$WORK/real" "$ROOT/docker/entrypoint-drclient.sh" init
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *owner* ]]
}

@test "entrypoint-client.sh refuses a symlinked key directory" {
  populate "$WORK/real"
  rm "$WORK/real/master.key" "$WORK/real/master.pem"
  ln -s "$WORK/real" "$WORK/keys"
  run env CLIENT_KEY_DIR="$WORK/keys" "$ROOT/docker/entrypoint-client.sh"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *symlink* ]]
}

@test "entrypoint-client.sh refuses a symlinked server01 key file" {
  mkdir "$WORK/keys"
  chmod 0700 "$WORK/keys"
  echo other > "$WORK/target"
  ln -s "$WORK/target" "$WORK/keys/server01.pem"
  run env CLIENT_KEY_DIR="$WORK/keys" "$ROOT/docker/entrypoint-client.sh"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *symlink* ]]
}
