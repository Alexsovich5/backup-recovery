#!/usr/bin/env bats
# scripts/check-container-env.sh inspects running containers and fails when
# a secret is in their environment, using a docker stub.

ROOT="$BATS_TEST_DIRNAME/../.."
CHECK="$ROOT/scripts/check-container-env.sh"

setup() {
  WORK="$BATS_TMPDIR/cce.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK/secrets"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"
  printf 'DB_PASSWORD=S3NTINEL-db\nDRFD_PASSWORD=S3NTINEL-fd\n' > "$WORK/secrets/drill.env"
  export DOCKER_STUB_ENV="$WORK/env"
  printf 'PYTHONDONTWRITEBYTECODE=1\nPATH=/usr/bin\n' > "$DOCKER_STUB_ENV"
}

teardown() {
  rm -rf "$WORK"
}

@test "a container without secrets in its environment passes" {
  run "$CHECK" "$WORK/secrets" c1 c2
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "a variable named like a password fails, and the value is not printed" {
  echo 'DIR_PASSWORD=whatever' >> "$DOCKER_STUB_ENV"
  run "$CHECK" "$WORK/secrets" c1
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *DIR_PASSWORD* ]]
  [[ "$output" != *whatever* ]]
}

@test "a secret value under an innocent name fails, and the value is not printed" {
  echo 'EXTRA=S3NTINEL-fd' >> "$DOCKER_STUB_ENV"
  run "$CHECK" "$WORK/secrets" c1
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *EXTRA* ]]
  [[ "$output" != *S3NTINEL* ]]
}

@test "no containers is an error, not a pass" {
  run "$CHECK" "$WORK/secrets"
  [ "$status" -eq 2 ]
}
