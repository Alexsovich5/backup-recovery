#!/usr/bin/env bats
# Static checks of docker-compose.yml: private key volumes are mounted only
# where they belong, and services get read-only, minimal views of the repo.

ROOT="$BATS_TEST_DIRNAME/../.."
COMPOSE="$ROOT/docker-compose.yml"

# mounts SERVICE prints the volume entries of SERVICE, one per line.
mounts() {
  awk -v svc="$1" '
    /^services:/ { in_s = 1; next }
    in_s && /^[^ #]/ { in_s = 0 }
    in_s && /^  [A-Za-z0-9_-]+:/ { cur = $1; sub(/:$/, "", cur); vol = 0; next }
    cur == svc && /^    volumes:/ { vol = 1; next }
    cur == svc && vol && /^      - / { sub(/^      - /, ""); print; next }
    cur == svc && /^    [A-Za-z]/ { vol = 0 }
  ' "$COMPOSE"
}

services() {
  awk '/^services:/ { s = 1; next } s && /^[^ #]/ { s = 0 }
       s && /^  [A-Za-z0-9_-]+:/ { n = $1; sub(/:$/, "", n); print n }' "$COMPOSE"
}

@test "the parser finds every service" {
  run services
  echo "$output"
  [ "$(echo "$output" | sort | tr '\n' ' ')" = "catalog director dr-client offsite server01 smtp tools " ]
}

@test "the master key safe is mounted into dr-client only" {
  for s in $(services); do
    m=$(mounts "$s")
    if [ "$s" = dr-client ]; then
      echo "$m" | grep -qE '^keysafe:/etc/bacula/keysafe$'
    elif echo "$m" | grep -q '^keysafe:'; then
      echo "keysafe mounted into $s"
      return 1
    fi
  done
}

@test "the client key volume is mounted into server01 only" {
  for s in $(services); do
    m=$(mounts "$s")
    if [ "$s" = server01 ]; then
      echo "$m" | grep -qE '^keys:/etc/bacula/keys$'
    elif echo "$m" | grep -q '^keys:'; then
      echo "keys mounted into $s"
      return 1
    fi
  done
}

@test "server01 gets the master certificate read-only from masterpub" {
  mounts server01 | grep -qx 'masterpub:/masterpub:ro'
}

@test "the director mounts no key volume" {
  run mounts director
  echo "$output"
  [ -n "$output" ]
  run grep -cE '^(keys|keysafe|masterpub):' <<< "$output"
  [ "$output" = "0" ]
}

@test "only tools mounts the whole repo; every service mount of the repo is read-only" {
  for s in $(services); do
    [ "$s" = tools ] && continue
    m=$(mounts "$s")
    echo "== $s"; echo "$m"
    run grep -cE '^\.:' <<< "$m"
    [ "$output" = "0" ]
    bad=$(echo "$m" | grep -E '^\./' | grep -vE ':ro$' || true)
    [ -z "$bad" ]
  done
}

@test "no service mounts build/, where make lint writes keys" {
  for s in $(services); do
    [ "$s" = tools ] && continue
    run grep -cE '^\./build' <<< "$(mounts "$s")"
    [ "$output" = "0" ]
  done
}

@test "no file in the repository (outside build/) contains private key material" {
  run grep -rlE --exclude-dir=.git --exclude-dir=build \
    '^-----BEGIN [A-Z ]*PRIVATE KEY-----' "$ROOT"
  echo "$output"
  [ "$status" -eq 1 ]
}
