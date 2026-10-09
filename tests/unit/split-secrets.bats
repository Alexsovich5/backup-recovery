#!/usr/bin/env bats
# scripts/split-secrets.sh writes one 0600 file per service holding only the
# passwords that service needs.

ROOT="$BATS_TEST_DIRNAME/../.."
SPLIT="$ROOT/scripts/split-secrets.sh"

setup() {
  WORK="$BATS_TMPDIR/split.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK"
  cat > "$WORK/all.env" <<'ENV'
DIR_PASSWORD=pw-dir
FD_PASSWORD=pw-fd
SD_PASSWORD=pw-sd
DB_PASSWORD=pw-db
DRILL_DB_PASSWORD=pw-drilldb
DRFD_PASSWORD=pw-drfd
OFFSITE_PASSWORD=pw-offsite
ENV
}

teardown() {
  rm -rf "$WORK"
}

# names FILE prints the variable names assigned in FILE, sorted.
names() {
  sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$1" | sort | tr '\n' ' '
}

# value FILE VAR prints VAR as bash reads it from FILE.
value() {
  (. "$1"; echo "${!2}")
}

@test "one file per service is written, each mode 0600" {
  run "$SPLIT" "$WORK/all.env" "$WORK/out"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(ls "$WORK/out" | tr '\n' ' ')" = "catalog.env director.env dr-client.env drill.env offsite.env server01.env " ]
  for f in "$WORK"/out/*; do
    [ "$(stat -c %a "$f")" = 600 ]
  done
}

@test "each service file holds only the passwords that service needs" {
  "$SPLIT" "$WORK/all.env" "$WORK/out"
  [ "$(names "$WORK/out/catalog.env")" = "DB_PASSWORD DRILL_DB_PASSWORD " ]
  [ "$(names "$WORK/out/director.env")" = "DB_PASSWORD DIR_PASSWORD FD_PASSWORD OFFSITE_PASSWORD SD_PASSWORD " ]
  [ "$(names "$WORK/out/server01.env")" = "FD_PASSWORD " ]
  [ "$(names "$WORK/out/offsite.env")" = "OFFSITE_PASSWORD " ]
  [ "$(names "$WORK/out/dr-client.env")" = "DRFD_PASSWORD " ]
  [ "$(names "$WORK/out/drill.env")" = "DB_PASSWORD DRFD_PASSWORD " ]
}

@test "the director never receives the recovery daemon password" {
  "$SPLIT" "$WORK/all.env" "$WORK/out"
  run grep -c 'pw-drfd\|pw-drilldb' "$WORK/out/director.env"
  [ "$output" = "0" ]
}

@test "the drill gets the scratch-catalog password as DB_PASSWORD, not the catalog's" {
  "$SPLIT" "$WORK/all.env" "$WORK/out"
  [ "$(value "$WORK/out/drill.env" DB_PASSWORD)" = "pw-drilldb" ]
  [ "$(value "$WORK/out/drill.env" DRFD_PASSWORD)" = "pw-drfd" ]
  run grep -c 'pw-db$' "$WORK/out/drill.env"
  [ "$output" = "0" ]
}

@test "values with spaces, quotes and dollar signs survive sourcing" {
  grep -v '^FD_PASSWORD=' "$WORK/all.env" > "$WORK/all2.env"
  printf '%s\n' "FD_PASSWORD='a b\"c\$d'" >> "$WORK/all2.env"
  mv "$WORK/all2.env" "$WORK/all.env"
  "$SPLIT" "$WORK/all.env" "$WORK/out"
  [ "$(value "$WORK/out/server01.env" FD_PASSWORD)" = 'a b"c$d' ]
}

@test "a missing password is refused and nothing is written" {
  sed -i '/^SD_PASSWORD=/d' "$WORK/all.env"
  run "$SPLIT" "$WORK/all.env" "$WORK/out"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *SD_PASSWORD* ]]
  [ ! -e "$WORK/out" ] || [ -z "$(ls -A "$WORK/out")" ]
}

@test "the passwords never appear in the script's output" {
  run "$SPLIT" "$WORK/all.env" "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" != *pw-* ]]
}

@test "usage errors exit 2" {
  run "$SPLIT"
  [ "$status" -eq 2 ]
  run "$SPLIT" "$WORK/missing.env" "$WORK/out"
  [ "$status" -eq 2 ]
}

@test "the shipped example holds every password the split needs" {
  run "$SPLIT" "$ROOT/config/passwords.env.example" "$WORK/out"
  echo "$output"
  [ "$status" -eq 0 ]
}
