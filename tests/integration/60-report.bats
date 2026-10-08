#!/usr/bin/env bats
# bin/catalog_report.py against the live catalog: OK after the earlier
# good jobs, CRITICAL after the test-only job server01-fail, whose
# ClientRunBeforeJob (/bin/false) makes it fail without stopping any
# container.

load helpers

PWFILE="$BATS_TMPDIR/t60-dbpass"

report() {
  "$SRC/bin/catalog_report.py" --host "$DB_HOST" --db bacula --user bacula \
    --password-file "$PWFILE" "$@"
}

setup() {
  export WAIT_INTERVAL WAIT_TIMEOUT
  printf '%s\n' "$DB_PASSWORD" > "$PWFILE"
  chmod 600 "$PWFILE"
}

@test "the report exits 0 after the earlier good jobs" {
  run report --format nagios
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "BACULA OK - "*"|"* ]]
}

# wait_job runs in the test shell, not under bats "run" (see 50-verify).
@test "server01-fail ends f within seconds and the report exits 2 naming it" {
  out=$(bcon "run job=server01-fail yes")
  echo "$out"
  jobid=$(printf '%s\n' "$out" | parse_jobid)
  [[ "$jobid" =~ ^[0-9]+$ ]]
  start=$(date +%s)
  st=$(WAIT_TIMEOUT=60 wait_job "$jobid") || st=timeout
  elapsed=$(( $(date +%s) - start ))
  echo "status=$st elapsed=${elapsed}s"
  [ "$st" = "f" ]
  [ "$elapsed" -le 30 ]

  run report
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "${lines[0]}" == "BACULA CRITICAL"* ]]
  [[ "$output" == *"server01-fail"* ]]

  run report --format nagios
  echo "$output"
  [ "$status" -eq 2 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"server01-fail"* ]]
}

@test "server01 is still reachable after the forced failure" {
  run bcon "status client=server01-fd"
  echo "$output"
  [[ "$output" == *"server01-fd Version"* ]]
}
