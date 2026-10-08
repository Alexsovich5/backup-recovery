#!/usr/bin/env bats
# Tests for scripts/render-config.sh <template> <output>.

RENDER="$BATS_TEST_DIRNAME/../../scripts/render-config.sh"

setup() {
  WORK="$BATS_TMPDIR/render-config.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK"
}

teardown() {
  rm -rf "$WORK"
}

@test "substitutes every placeholder" {
  printf '%s\n' 'Name = @ALPHA@' 'Password = "@BETA_2@"' 'Both = @ALPHA@-@BETA_2@' > "$WORK/in.conf"
  ALPHA=one BETA_2=two run "$RENDER" "$WORK/in.conf" "$WORK/out.conf"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/out.conf")" = 'Name = one
Password = "two"
Both = one-two' ]
}

@test "keeps lines without placeholders and a mail address untouched" {
  printf '%s\n' 'mail = root@localhost = all' '' 'x = @ALPHA@' > "$WORK/in.conf"
  ALPHA=1 run "$RENDER" "$WORK/in.conf" "$WORK/out.conf"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/out.conf")" = 'mail = root@localhost = all

x = 1' ]
}

@test "exits 3 when a variable is unset and writes no output" {
  printf '%s\n' 'a = @ALPHA@' 'b = @RENDER_TEST_UNSET@' > "$WORK/in.conf"
  unset RENDER_TEST_UNSET
  ALPHA=1 run "$RENDER" "$WORK/in.conf" "$WORK/out.conf"
  [ "$status" -eq 3 ]
  [[ "$output" == *RENDER_TEST_UNSET* ]]
  [ ! -e "$WORK/out.conf" ]
}

@test "an empty but set variable is substituted" {
  printf '%s\n' 'a = "@EMPTY@"' > "$WORK/in.conf"
  EMPTY= run "$RENDER" "$WORK/in.conf" "$WORK/out.conf"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/out.conf")" = 'a = ""' ]
}

@test "exits 3 when a stray @FOO@ remains" {
  printf '%s\n' 'a = @ALPHA@' 'b = @foo@' > "$WORK/in.conf"
  ALPHA=1 run "$RENDER" "$WORK/in.conf" "$WORK/out.conf"
  [ "$status" -eq 3 ]
  [[ "$output" == *"@foo@"* ]]
  [ ! -e "$WORK/out.conf" ]
}

@test "exits 3 when a value introduces a placeholder" {
  printf '%s\n' 'a = @ALPHA@' > "$WORK/in.conf"
  ALPHA='@FOO@' FOO=x run "$RENDER" "$WORK/in.conf" "$WORK/out.conf"
  [ "$status" -eq 3 ]
}

@test "leaves values containing / and & intact" {
  printf '%s\n' 'Dir = @PATHVAL@' 'Pw = "@AMPVAL@"' > "$WORK/in.conf"
  PATHVAL='/src/build/keys' AMPVAL='a&b\1/c&&' run "$RENDER" "$WORK/in.conf" "$WORK/out.conf"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$WORK/out.conf")" = 'Dir = /src/build/keys' ]
  [ "$(sed -n 2p "$WORK/out.conf")" = 'Pw = "a&b\1/c&&"' ]
}

@test "usage error exits 2" {
  run "$RENDER" "$WORK/only-one-arg"
  [ "$status" -eq 2 ]
}

@test "missing template exits 2" {
  run "$RENDER" "$WORK/nope.conf" "$WORK/out.conf"
  [ "$status" -eq 2 ]
}
