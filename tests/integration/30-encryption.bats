#!/usr/bin/env bats
# server01-fd encrypts file data with its PKI keypair, so the marker in
# secret.txt never reaches a Full-* volume in plain text. The control job
# backs up the same file from backup-fd (no PKI, no compression) to show
# that the volume check does see an unencrypted copy.

load helpers

VOLDIR=/var/lib/bacula/volumes
MARKER=PLAINTEXT-MARKER-7f3a

@test "control: plaintext-control ends T and its Default volume holds the marker" {
  run run_and_wait plaintext-control
  echo "$output"
  [ "$status" -eq 0 ]
  ls "$VOLDIR"/Default-*
  run grep -l "$MARKER" "$VOLDIR"/Default-*
  echo "$output"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "server01 full backup leaves no plaintext marker in any Full volume" {
  run "$SRC/scripts/backup.sh" server01 full --no-verify
  echo "$output"
  [ "$status" -eq 0 ]
  ls "$VOLDIR"/Full-*
  run grep -l "$MARKER" "$VOLDIR"/Full-*
  echo "$output"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "the encrypted server01 backup saved secret.txt" {
  jobid=$(last_jobid server01-full)
  [[ "$jobid" =~ ^[0-9]+$ ]]
  run sql "SELECT COUNT(*) FROM File f JOIN Filename n ON n.FilenameId = f.FilenameId WHERE f.JobId = $jobid AND n.Name = 'secret.txt'"
  echo "$output"
  [ "$output" -ge 1 ]
}

@test "the encrypted server01 backup reports encryption and logs no encryption error" {
  jobid=$(last_jobid server01-full)
  [[ "$jobid" =~ ^[0-9]+$ ]]
  joblog=$(bcon "list joblog jobid=$jobid")
  echo "$joblog"
  grep -qE 'Encryption:[[:space:]]+yes' <<< "$joblog"
  run grep -c 'Encryption error' <<< "$joblog"
  [ "$output" = "0" ]
  run grep -E "JobId $jobid:.*Encryption error" /var/log/bacula/bacula.log
  echo "$output"
  [ "$status" -eq 1 ]
}
