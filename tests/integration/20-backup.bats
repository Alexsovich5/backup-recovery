#!/usr/bin/env bats
# A full backup of server01 runs end to end, and the shell parsers from
# scripts/lib/common.sh work on real bconsole output.

load helpers

@test "backup.sh server01 full --no-verify exits 0" {
  run "$SRC/scripts/backup.sh" server01 full --no-verify
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the catalog holds a terminated server01-full backup with files" {
  run sql "SELECT COUNT(*) FROM Job WHERE Type='B' AND Name='server01-full' AND JobStatus='T' AND JobFiles > 0"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "parse_jobid and job_status work on real bconsole output" {
  out=$(bcon "run job=server01-full yes")
  echo "$out"
  jobid=$(printf '%s\n' "$out" | parse_jobid)
  echo "jobid=$jobid"
  [[ "$jobid" =~ ^[0-9]+$ ]]
  st=$(wait_job "$jobid")
  [ "$st" = "T" ]
  run job_status "$jobid"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "T" ]
  [ "$(last_jobid server01-full)" = "$jobid" ]
}
