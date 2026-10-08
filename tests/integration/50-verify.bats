#!/usr/bin/env bats
# Every backup gets exactly one VolumeToCatalog verify: the scheduled
# server01-backup job queues it through its RunScript, backup.sh queues it
# for on-demand runs. restore-test.sh restores into /restores and checks
# the files against a manifest of the client data.

load helpers

DATA=/clientdata/server01
MANIFEST="$BATS_TMPDIR/t50-manifest"

setup() {
  export WAIT_INTERVAL WAIT_TIMEOUT
}

verify_count() {
  sql "SELECT COUNT(*) FROM Job WHERE Name='Verify-server01'"
}

# wait_verify_after JOBID SECS
# Waits until a Verify-server01 job newer than JOBID has finished and
# prints "<jobid> <status>". Returns 1 when none appears in SECS seconds.
wait_verify_after() {
  local after=$1 secs=$2 i id st
  for ((i = 0; i <= secs; i++)); do
    id=$(sql "SELECT MIN(JobId) FROM Job WHERE Name='Verify-server01' AND JobId > $after")
    if [[ "$id" =~ ^[0-9]+$ ]]; then
      st=$(wait_job "$id") || st=timeout
      echo "$id $st"
      return 0
    fi
    sleep 1
  done
  return 1
}

# These steps call wait_job in the test shell and so avoid bats "run":
# in bats 0.3.1 "run" leaves IFS set to a newline, which stops wait_job
# from splitting its list of terminal statuses.
@test "a scheduled server01-backup run queues exactly one verify that ends T" {
  before=$(verify_count)
  echo "verify rows before: $before"

  result=$(run_and_wait server01-backup level=Incremental)
  echo "backup: $result"
  [ "${result#* }" = "T" ]
  backup_id=${result%% *}

  result=$(wait_verify_after "$backup_id" 120)
  echo "verify: $result"
  verify_id=${result%% *}
  [[ "$verify_id" =~ ^[0-9]+$ ]]
  [ "$verify_id" -gt "$backup_id" ]
  [ "${result#* }" = "T" ]

  # Give a second, unwanted trigger time to show up before counting.
  sleep 10
  after=$(verify_count)
  echo "verify rows after: $after"
  [ "$after" -eq $((before + 1)) ]
  [ "$(sql "SELECT Level FROM Job WHERE JobId=$verify_id")" = "O" ]
}

@test "backup.sh server01 incremental queues exactly one verify" {
  before=$(verify_count)
  run "$SRC/scripts/backup.sh" server01 incremental
  echo "$output"
  [ "$status" -eq 0 ]
  sleep 10
  after=$(verify_count)
  echo "verify rows before: $before after: $after"
  [ "$after" -eq $((before + 1)) ]
  [ "$(sql "SELECT JobStatus FROM Job WHERE Name='Verify-server01' ORDER BY JobId DESC LIMIT 1")" = "T" ]
}

@test "restore-test.sh passes against a manifest of the backed-up data" {
  run "$SRC/scripts/make-manifest.sh" "$DATA" "$MANIFEST"
  [ "$status" -eq 0 ]
  [ -s "$MANIFEST" ]
  rm -rf /restores/t50

  run "$SRC/scripts/restore-test.sh" --client server01 --manifest "$MANIFEST" --where /restores/t50
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"files verified"* ]]
}

@test "restore-test.sh fails with a tampered manifest and names the file" {
  [ -s "$MANIFEST" ]
  tampered="$BATS_TMPDIR/t50-tampered"
  rel=$(awk 'NR == 1 { print $2 }' "$MANIFEST")
  [ -n "$rel" ]
  awk 'NR == 1 { $1 = "00000000000000000000000000000000" } { print }' OFS='  ' \
    "$MANIFEST" > "$tampered"
  run cmp -s "$MANIFEST" "$tampered"
  [ "$status" -eq 1 ]

  run "$SRC/scripts/restore-test.sh" --client server01 --manifest "$tampered" --where /restores/t50
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$rel: FAILED"* ]]
}
