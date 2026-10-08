#!/usr/bin/env bats
# Tests for scripts/gen-keys.sh [--client|--master] <outdir> [<client-name>].

GENKEYS="$BATS_TEST_DIRNAME/../../scripts/gen-keys.sh"

setup() {
  WORK="$BATS_TMPDIR/gen-keys.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK"
}

teardown() {
  rm -rf "$WORK"
}

modulus_cert() { openssl x509 -noout -modulus -in "$1"; }
modulus_key() { openssl rsa -noout -modulus -in "$1"; }

@test "creates the client keypair file, master cert and master key" {
  run "$GENKEYS" "$WORK/keys" server01
  echo "$output"
  [ "$status" -eq 0 ]
  [ -s "$WORK/keys/server01.pem" ]
  [ -s "$WORK/keys/master.cert" ]
  [ -s "$WORK/keys/master.key" ]
  grep -q 'PRIVATE KEY' "$WORK/keys/server01.pem"
  grep -q 'BEGIN CERTIFICATE' "$WORK/keys/server01.pem"
  grep -q 'BEGIN CERTIFICATE' "$WORK/keys/master.cert"
  run grep -c 'PRIVATE KEY' "$WORK/keys/master.cert"
  [ "$output" = "0" ]
}

@test "the client cert in the pem matches the client key" {
  "$GENKEYS" "$WORK/keys" server01
  cert_mod=$(modulus_cert "$WORK/keys/server01.pem")
  key_mod=$(modulus_key "$WORK/keys/server01.pem")
  echo "cert=$cert_mod key=$key_mod"
  [[ "$cert_mod" == Modulus=* ]]
  [ "$cert_mod" = "$key_mod" ]
  [ "$(modulus_cert "$WORK/keys/server01.cert")" = "$(modulus_key "$WORK/keys/server01.key")" ]
}

@test "the master cert matches the master key and differs from the client key" {
  "$GENKEYS" "$WORK/keys" server01
  master_cert=$(modulus_cert "$WORK/keys/master.cert")
  master_key=$(modulus_key "$WORK/keys/master.key")
  [[ "$master_cert" == Modulus=* ]]
  [ "$master_cert" = "$master_key" ]
  [ "$master_cert" != "$(modulus_key "$WORK/keys/server01.pem")" ]
}

@test "private key files are readable by the owner only" {
  "$GENKEYS" "$WORK/keys" server01
  for f in server01.key server01.pem master.key; do
    perm=$(stat -c %a "$WORK/keys/$f")
    echo "$f $perm"
    [ "$perm" = "600" ]
  done
}

@test "refuses to overwrite existing keys and leaves them unchanged" {
  "$GENKEYS" "$WORK/keys" server01
  before=$(md5sum "$WORK/keys/server01.pem" "$WORK/keys/master.key")
  run "$GENKEYS" "$WORK/keys" server01
  echo "$output"
  [ "$status" -eq 1 ]
  [ "$(md5sum "$WORK/keys/server01.pem" "$WORK/keys/master.key")" = "$before" ]
}

@test "refuses when only the master key already exists" {
  mkdir -p "$WORK/keys"
  echo keep > "$WORK/keys/master.key"
  run "$GENKEYS" "$WORK/keys" server01
  [ "$status" -eq 1 ]
  [ "$(cat "$WORK/keys/master.key")" = "keep" ]
  [ ! -e "$WORK/keys/server01.pem" ]
}

@test "the full set also writes master.pem holding the master key and cert" {
  "$GENKEYS" "$WORK/keys" server01
  grep -q 'PRIVATE KEY' "$WORK/keys/master.pem"
  grep -q 'BEGIN CERTIFICATE' "$WORK/keys/master.pem"
  [ "$(modulus_cert "$WORK/keys/master.pem")" = "$(modulus_key "$WORK/keys/master.key")" ]
  [ "$(stat -c %a "$WORK/keys/master.pem")" = "600" ]
}

@test "--client writes only the client keypair, never master key material" {
  run "$GENKEYS" --client "$WORK/keys" server01
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(ls "$WORK/keys" | sort | tr '\n' ' ')" = "server01.cert server01.key server01.pem " ]
  [ "$(modulus_cert "$WORK/keys/server01.pem")" = "$(modulus_key "$WORK/keys/server01.pem")" ]
}

@test "--master writes only master.key, master.cert and master.pem" {
  run "$GENKEYS" --master "$WORK/safe"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(ls "$WORK/safe" | sort | tr '\n' ' ')" = "master.cert master.key master.pem " ]
  [ "$(modulus_cert "$WORK/safe/master.cert")" = "$(modulus_key "$WORK/safe/master.key")" ]
  run grep -c 'PRIVATE KEY' "$WORK/safe/master.cert"
  [ "$output" = "0" ]
  for f in master.key master.pem; do
    [ "$(stat -c %a "$WORK/safe/$f")" = "600" ]
  done
}

@test "--master refuses to overwrite an existing master key" {
  mkdir -p "$WORK/safe"
  echo keep > "$WORK/safe/master.key"
  run "$GENKEYS" --master "$WORK/safe"
  [ "$status" -eq 1 ]
  [ "$(cat "$WORK/safe/master.key")" = "keep" ]
  [ ! -e "$WORK/safe/master.cert" ]
}

@test "--client and --master take the right number of arguments" {
  run "$GENKEYS" --client "$WORK/keys"
  [ "$status" -eq 2 ]
  run "$GENKEYS" --master "$WORK/safe" server01
  [ "$status" -eq 2 ]
  run "$GENKEYS" --bogus "$WORK/keys" server01
  [ "$status" -eq 2 ]
  [ ! -e "$WORK/keys" ]
  [ ! -e "$WORK/safe" ]
}

@test "usage error exits 2" {
  run "$GENKEYS"
  [ "$status" -eq 2 ]
  [[ "$output" == *usage* ]]
  run "$GENKEYS" "$WORK/keys"
  [ "$status" -eq 2 ]
  run "$GENKEYS" "$WORK/keys" server01 extra
  [ "$status" -eq 2 ]
  run "$GENKEYS" "$WORK/keys" "bad/name"
  [ "$status" -eq 2 ]
  run "$GENKEYS" --client "$WORK/keys" master
  [ "$status" -eq 2 ]
  [ ! -e "$WORK/keys" ]
}
