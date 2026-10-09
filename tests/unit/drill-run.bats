#!/usr/bin/env bats
# scripts/drill-run.sh waits for drill-fd, builds the manifest of the client
# data and hands both to dr-drill.sh (replaced here by a recording stub).

ROOT="$BATS_TEST_DIRNAME/../.."
RUN="$ROOT/scripts/drill-run.sh"

setup() {
  WORK="$BATS_TMPDIR/drill-run.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK/data/docs" "$WORK/offsite"
  echo alpha > "$WORK/data/alpha.txt"
  echo runbook > "$WORK/data/docs/runbook.txt"
  cat > "$WORK/dr-drill-stub.sh" <<'SH'
#!/bin/bash
echo "$*" > "$STUB_ARGS"
manifest=
while [ "$#" -gt 0 ]; do
  [ "$1" = --manifest ] && manifest=$2
  shift
done
cp "$manifest" "$STUB_MANIFEST"
exit "${STUB_EXIT:-0}"
SH
  chmod +x "$WORK/dr-drill-stub.sh"
  export DR_DRILL_SH="$WORK/dr-drill-stub.sh"
  export STUB_ARGS="$WORK/args" STUB_MANIFEST="$WORK/manifest"
  export DRILL_DATA_DIR="$WORK/data" OFFSITE_DIR="$WORK/offsite"
  export DRFD_HOST=127.0.0.1 DRFD_PORT=39202 DRILL_FD_TIMEOUT=2
  LISTENER=
}

teardown() {
  [ -z "$LISTENER" ] || kill "$LISTENER" 2>/dev/null
  rm -rf "$WORK"
}

listen() {
  python -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $DRFD_PORT))
s.listen(5)
time.sleep(20)
" &
  LISTENER=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    (exec 3<> "/dev/tcp/127.0.0.1/$DRFD_PORT") 2>/dev/null && return 0
    sleep 0.3
  done
  return 1
}

@test "it gives up when drill-fd does not answer, without running the drill" {
  run "$RUN"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"drill-fd"* ]]
  [ ! -e "$STUB_ARGS" ]
}

@test "it passes the offsite copy, a manifest of the client data and extra arguments to dr-drill.sh" {
  listen
  run "$RUN" --restore-dir /somewhere
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q -- "--offsite $WORK/offsite --manifest " "$STUB_ARGS"
  grep -q -- '--restore-dir /somewhere' "$STUB_ARGS"
  [ "$(wc -l < "$STUB_MANIFEST")" -eq 2 ]
  grep -q '  alpha.txt$' "$STUB_MANIFEST"
  grep -q '  docs/runbook.txt$' "$STUB_MANIFEST"
}

@test "it returns the exit status of dr-drill.sh and removes the manifest" {
  listen
  export STUB_EXIT=1
  run "$RUN"
  [ "$status" -eq 1 ]
  manifest=$(sed -n 's/.*--manifest \([^ ]*\).*/\1/p' "$STUB_ARGS")
  [ -n "$manifest" ]
  [ ! -e "$manifest" ]
}
