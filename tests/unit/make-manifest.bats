#!/usr/bin/env bats
# Tests for scripts/make-manifest.sh <dir> <out>.

MANIFEST="$BATS_TEST_DIRNAME/../../scripts/make-manifest.sh"

setup() {
  WORK="$BATS_TMPDIR/manifest.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK/tree/sub/deeper"
  echo zeta > "$WORK/tree/zeta.txt"
  echo alpha > "$WORK/tree/alpha.txt"
  echo nested > "$WORK/tree/sub/deeper/n.txt"
  printf 'with space\n' > "$WORK/tree/sub/a b.txt"
}

teardown() {
  rm -rf "$WORK"
}

@test "lists every file with a path relative to the directory" {
  run "$MANIFEST" "$WORK/tree" "$WORK/m"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WORK/m")" -eq 4 ]
  run grep -c "$WORK" "$WORK/m"
  [ "$output" = "0" ]
  grep -q '  sub/deeper/n.txt$' "$WORK/m"
  grep -q "  alpha.txt$" "$WORK/m"
}

@test "output is sorted by path" {
  "$MANIFEST" "$WORK/tree" "$WORK/m"
  [ "$(cut -c35- "$WORK/m")" = 'alpha.txt
sub/a b.txt
sub/deeper/n.txt
zeta.txt' ]
}

@test "md5sum -c passes from the directory and fails after a change" {
  "$MANIFEST" "$WORK/tree" "$WORK/m"
  (cd "$WORK/tree" && md5sum -c "$WORK/m")
  echo changed > "$WORK/tree/alpha.txt"
  run bash -c "cd '$WORK/tree' && md5sum -c '$WORK/m'"
  [ "$status" -ne 0 ]
}

@test "a missing directory exits 1" {
  run "$MANIFEST" "$WORK/nope" "$WORK/m"
  [ "$status" -eq 1 ]
}

@test "wrong argument count exits 2" {
  run "$MANIFEST" "$WORK/tree"
  [ "$status" -eq 2 ]
}
