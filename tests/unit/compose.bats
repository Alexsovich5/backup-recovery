#!/usr/bin/env bats
# Static checks of docker-compose.yml: private key volumes are mounted only
# where they belong, and services get read-only, minimal views of the repo.

ROOT="$BATS_TEST_DIRNAME/../.."
COMPOSE="$ROOT/docker-compose.yml"

# entries SERVICE KEY prints the list entries of SERVICE's KEY, one per
# line, for both "key:" followed by "- item" lines and inline [a, b] lists.
entries() {
  awk -v svc="$1" -v key="$2" '
    /^services:/ { in_s = 1; next }
    in_s && /^[^ #]/ { in_s = 0 }
    in_s && /^  [A-Za-z0-9_-]+:/ { cur = $1; sub(/:$/, "", cur); vol = 0; next }
    cur == svc && $1 == key ":" {
      vol = 1
      if ($0 ~ /\[/) {
        line = $0; sub(/^[^\[]*\[/, "", line); sub(/\].*$/, "", line)
        n = split(line, a, /, */)
        for (i = 1; i <= n; i++) { gsub(/"/, "", a[i]); print a[i] }
        vol = 0
      }
      next
    }
    cur == svc && vol && /^      - / { sub(/^      - /, ""); gsub(/"/, ""); print; next }
    cur == svc && /^    [A-Za-z]/ { vol = 0 }
  ' "$COMPOSE"
}

# mounts SERVICE prints the volume entries of SERVICE, one per line.
mounts() { entries "$1" volumes; }

# attached SERVICE prints the networks SERVICE joins.
attached() { entries "$1" networks; }

# secrets_of SERVICE prints the secrets handed to SERVICE.
secrets_of() { entries "$1" secrets; }

services() {
  awk '/^services:/ { s = 1; next } s && /^[^ #]/ { s = 0 }
       s && /^  [A-Za-z0-9_-]+:/ { n = $1; sub(/:$/, "", n); print n }' "$COMPOSE"
}

@test "the parser finds every service" {
  run services
  echo "$output"
  [ "$(echo "$output" | sort | tr '\n' ' ')" = "catalog director dr-client drill offsite server01 smtp tools " ]
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

@test "dr-client and drill are behind the drill profile and nothing else is" {
  for s in $(services); do
    p=$(entries "$s" profiles | tr '\n' ' ')
    case "$s" in
      dr-client|drill) [ "$p" = "drill " ] ;;
      tools) [ "$p" = "tools " ] ;;
      *) [ -z "$p" ] ;;
    esac
  done
}

@test "dr-client sits on the drill network only and the director is not on it" {
  [ "$(attached dr-client | tr '\n' ' ')" = "drillnet " ]
  run grep -c '^drillnet$' <<< "$(attached director)"
  [ "$output" = "0" ]
  for s in catalog smtp offsite server01 tools; do
    run grep -c '^drillnet$' <<< "$(attached "$s")"
    [ "$output" = "0" ]
  done
}

@test "the drill runner is the only service on both networks" {
  a=$(attached drill | sort | tr '\n' ' ')
  [ "$a" = "backupnet drillnet " ]
}

@test "the drill network is internal and both networks sit inside 172.44.0.0/24" {
  net=$(awk '/^networks:/ { n = 1; next } n' "$COMPOSE")
  echo "$net"
  grep -qE '^  drillnet:' <<< "$net"
  awk '/^  drillnet:/ { d = 1; next } /^  [a-z]/ { d = 0 } d' <<< "$net" | grep -qE 'internal: true'
  subnets=$(grep -oE 'subnet: [0-9./]+' <<< "$net" | awk '{ print $2 }')
  [ "$(echo "$subnets" | wc -l)" -eq 2 ]
  for sn in $subnets; do
    [[ "$sn" =~ ^172\.44\.0\.[0-9]+/(25|26|27|28)$ ]]
  done
}

@test "the master key and the drill password reach the drill hosts only" {
  # keysafe: dr-client (tested above). drillrestores: dr-client and drill.
  for s in $(services); do
    m=$(mounts "$s")
    case "$s" in
      dr-client|drill) echo "$m" | grep -qE '^drillrestores:/drill-restores$' ;;
      *) if echo "$m" | grep -q '^drillrestores:'; then echo "drillrestores in $s"; return 1; fi ;;
    esac
  done
}

@test "every service but smtp and tools gets exactly its own secret file" {
  for s in catalog director dr-client drill offsite server01; do
    [ "$(secrets_of "$s" | tr '\n' ' ')" = "$s " ]
  done
  for s in smtp tools; do
    [ -z "$(secrets_of "$s")" ]
  done
}

@test "secrets are file-based files under ./secrets and no service mounts that directory" {
  for s in catalog director dr-client drill offsite server01; do
    grep -qE "^  $s:" <<< "$(awk '/^secrets:/ { n = 1; next } /^[a-z]/ { n = 0 } n' "$COMPOSE")"
    grep -qE "file: \./secrets/$s\.env" "$COMPOSE"
  done
  for s in $(services); do
    run grep -cE '^\./secrets' <<< "$(mounts "$s")"
    [ "$output" = "0" ]
  done
}

@test "the tools container hides ./secrets from its whole-repo mount" {
  entries tools tmpfs | grep -qx '/src/secrets'
}

@test "the director mounts only the integration suites from tests/" {
  m=$(mounts director)
  grep -qx './tests/integration:/src/tests/integration:ro' <<< "$m"
  run grep -cE '^\./tests(:|/[^i])' <<< "$m"
  [ "$output" = "0" ]
}

@test "the shared settings file holds no password" {
  run grep -n 'PASSWORD' "$ROOT/config/bacula.env.example"
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "no service passes a password through environment or env_file" {
  run grep -nE '[A-Za-z_]*(PASSWORD|PASSWD|SECRET|TOKEN)[A-Za-z_]*:|env_file' "$COMPOSE"
  echo "$output"
  [ "$status" -eq 1 ]
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
