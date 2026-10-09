#!/usr/bin/env bats
# README cross-references: every `make TARGET` it tells the reader to run is
# a Makefile target, and every test file it cites exists.

ROOT="$BATS_TEST_DIRNAME/../.."
README="$ROOT/README.md"

@test "every make target named in the README exists in the Makefile" {
  missing=""
  for t in $(grep -o '`make [a-z][a-z0-9_-]*' "$README" | sed 's/^`make //' | sort -u); do
    grep -q "^$t:" "$ROOT/Makefile" || missing="$missing $t"
  done
  [ -z "$missing" ] || { echo "missing make targets:$missing"; false; }
}

@test "every test file path cited in the README exists" {
  missing=""
  for p in $(grep -o 'tests/[A-Za-z0-9_./-]*\.\(bats\|py\)' "$README" | sort -u); do
    [ -f "$ROOT/$p" ] || missing="$missing $p"
  done
  [ -z "$missing" ] || { echo "missing test files:$missing"; false; }
}
