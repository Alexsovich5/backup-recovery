#!/usr/bin/env bats
# The compose stack is up: catalog, Director, Storage Daemon and both File
# Daemons answer, and only server01-backup is scheduled.

load helpers

# Prints the "Scheduled Jobs:" section of "status dir".
scheduled_jobs() {
  bcon "status dir" | awk '/^Scheduled Jobs:/{p=1; next} p && /^====$/{exit} p'
}

@test "bacula-dir -t accepts the Director config against the live catalog" {
  run bacula-dir -t -c /etc/bacula/bacula-dir.conf
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "status dir reports backup-dir 5.2.6" {
  run bcon "status dir"
  echo "$output"
  [[ "$output" == *"backup-dir Version: 5.2.6"* ]]
}

@test "the server01 File Daemon answers" {
  run bcon "status client=server01-fd"
  echo "$output"
  [[ "$output" == *"server01-fd Version"* ]]
}

@test "the director-host File Daemon backup-fd answers" {
  run bcon "status client=backup-fd"
  echo "$output"
  [[ "$output" == *"backup-fd Version"* ]]
  [[ "$output" != *"Failed to connect"* ]]
}

@test "the Storage Daemon answers for storage File" {
  run bcon "status storage=File"
  echo "$output"
  [[ "$output" == *"backup-sd Version"* ]]
  [[ "$output" == *"FileStorage"* ]]
}

@test "server01-backup is scheduled and the level-named jobs are not" {
  run scheduled_jobs
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qw 'server01-backup'
  for j in server01-full server01-incremental server01-differential; do
    if echo "$output" | grep -qw "$j"; then
      echo "$j is scheduled"
      return 1
    fi
  done
}

@test "show schedule=WeeklyCycle lists the Full, Differential and Incremental runs" {
  run bcon "show schedule=WeeklyCycle"
  echo "$output"
  [[ "$output" == *"Schedule: name=WeeklyCycle"* ]]
  [ "$(echo "$output" | grep -c -- '--> Run Level=')" -eq 3 ]
  echo "$output" | grep -q -- '--> Run Level=Full'
  echo "$output" | grep -q -- '--> Run Level=Differential'
  echo "$output" | grep -q -- '--> Run Level=Incremental'
}
