#!/usr/bin/env bats
# Tests for scripts/restore-test.sh. The restore step is replaced by
# tests/unit/stubs/restore.sh (through $RESTORE_SH), which records its
# arguments and copies a prepared tree under the --where prefix the way a
# Bacula restore would.

ROOT="$BATS_TEST_DIRNAME/../.."
RESTORE_TEST="$ROOT/scripts/restore-test.sh"

setup() {
  WORK="$BATS_TMPDIR/restore-test.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK/tree/srv/data/docs" "$WORK/src"
  echo alpha > "$WORK/tree/srv/data/alpha.txt"
  echo runbook > "$WORK/tree/srv/data/docs/runbook.txt"
  (cd "$WORK/tree/srv/data" && md5sum alpha.txt docs/runbook.txt) > "$WORK/manifest"
  export RESTORE_SH="$BATS_TEST_DIRNAME/stubs/restore.sh"
  export RESTORE_STUB_TREE="$WORK/tree"
  export RESTORE_STUB_ARGS="$WORK/restore.args"
  export LOG_FILE="$WORK/restore-test.log"
  unset RESTORE_STUB_EXIT
}

teardown() {
  rm -rf "$WORK"
}

@test "all checksums match: exits 0 and reports the file count" {
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/manifest" --where "$WORK/r"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 files verified"* ]]
}

@test "a changed file exits 1 and names the file" {
  echo tampered > "$WORK/tree/srv/data/docs/runbook.txt"
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/manifest" --where "$WORK/r"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"docs/runbook.txt: FAILED"* ]]
  [[ "$output" != *"alpha.txt: FAILED"* ]]
}

@test "a file missing from the restore exits 1 and names it" {
  rm "$WORK/tree/srv/data/alpha.txt"
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/manifest" --where "$WORK/r"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"alpha.txt"* ]]
}

@test "a stale copy left by an earlier restore does not hide a missing file" {
  mkdir -p "$WORK/r/srv/data"
  echo alpha > "$WORK/r/srv/data/alpha.txt"
  rm "$WORK/tree/srv/data/alpha.txt"
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/manifest" --where "$WORK/r"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"alpha.txt"* ]]
}

@test "a missing manifest exits 2 without restoring" {
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/nope" --where "$WORK/r"
  echo "$output"
  [ "$status" -eq 2 ]
  [ ! -e "$RESTORE_STUB_ARGS" ]
}

@test "--where and --client are passed to restore.sh" {
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/manifest" --where "$WORK/r"
  [ "$status" -eq 0 ]
  [ "$(cat "$RESTORE_STUB_ARGS")" = "--client server01 --where $WORK/r" ]
}

@test "--root selects the directory under --where that is checked" {
  mkdir -p "$WORK/tree/data/app"
  echo app > "$WORK/tree/data/app/app.conf"
  (cd "$WORK/tree/data/app" && md5sum app.conf) > "$WORK/app.manifest"
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/app.manifest" \
    --where "$WORK/r" --root /data/app
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$WORK/r/data/app/app.conf" ]
  [[ "$output" == *"1 files verified"* ]]
}

@test "a relative manifest path is resolved before checking" {
  cd "$WORK"
  run "$RESTORE_TEST" --client server01 --manifest manifest --where "$WORK/r"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "a failed restore exits 1 and checks nothing" {
  export RESTORE_STUB_EXIT=1
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/manifest" --where "$WORK/r"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" != *"files verified"* ]]
}

@test "missing --client exits 2" {
  run "$RESTORE_TEST" --manifest "$WORK/manifest" --where "$WORK/r"
  [ "$status" -eq 2 ]
  [[ "$output" == *Usage:* ]]
}

@test "missing --manifest exits 2" {
  run "$RESTORE_TEST" --client server01 --where "$WORK/r"
  [ "$status" -eq 2 ]
}

@test "--where / is refused with exit 2" {
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/manifest" --where /
  [ "$status" -eq 2 ]
  [ ! -e "$RESTORE_STUB_ARGS" ]
}

@test "a manifest path leaving the restore directory exits 2 and deletes nothing" {
  mkdir -p "$WORK/live/data" "$WORK/r/srv/data"
  echo precious > "$WORK/live/data/keep.txt"
  h=$(md5sum < "$WORK/live/data/keep.txt" | cut -d' ' -f1)
  cp "$WORK/manifest" "$WORK/bad.manifest"
  printf '%s  %s\n' "$h" ../../../live/data/keep.txt >> "$WORK/bad.manifest"
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/bad.manifest" --where "$WORK/r"
  echo "$output"
  [ "$status" -eq 2 ]
  [ "$(cat "$WORK/live/data/keep.txt")" = "precious" ]
  [ ! -e "$RESTORE_STUB_ARGS" ]
}

@test "an absolute manifest path exits 2 instead of checking a live file" {
  h=$(md5sum < "$WORK/tree/srv/data/alpha.txt" | cut -d' ' -f1)
  printf '%s  %s\n' "$h" "$WORK/tree/srv/data/alpha.txt" > "$WORK/abs.manifest"
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/abs.manifest" --where "$WORK/r"
  echo "$output"
  [ "$status" -eq 2 ]
  [ -f "$WORK/tree/srv/data/alpha.txt" ]
  [ ! -e "$RESTORE_STUB_ARGS" ]
}

@test "unknown option exits 2" {
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/manifest" --bogus
  [ "$status" -eq 2 ]
}

@test "a symlinked directory left in the restore directory is refused and nothing behind it is deleted" {
  mkdir -p "$WORK/r/srv/data" "$WORK/live"
  echo live > "$WORK/live/runbook.txt"
  ln -s "$WORK/live" "$WORK/r/srv/data/docs"
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/manifest" --where "$WORK/r"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *symlink* ]]
  [ "$(cat "$WORK/live/runbook.txt")" = live ]
  [ ! -e "$WORK/restore.args" ]
}

@test "a restored symlink in place of a manifest file fails the test" {
  echo alpha > "$WORK/elsewhere"
  rm "$WORK/tree/srv/data/alpha.txt"
  ln -s "$WORK/elsewhere" "$WORK/tree/srv/data/alpha.txt"
  run "$RESTORE_TEST" --client server01 --manifest "$WORK/manifest" --where "$WORK/r"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *symlink* ]]
  [[ "$output" != *"files verified"* ]]
}
