#!/usr/bin/env bats
# Job notifications reach the SMTP sink: the Director's Messages resource
# mails the job report through bsmtp, and backup.sh mails its own summary.
# Both are read back from the sink log on the read-only maillog volume.

load helpers

MAILLOG=/var/log/smtp-sink/smtp.log

setup() {
  export WAIT_INTERVAL WAIT_TIMEOUT SMTP_HOST ADMIN_EMAIL
}

@test "backup.sh server01 incremental --no-verify exits 0" {
  run "$SRC/scripts/backup.sh" server01 incremental --no-verify
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "the Director's job report for server01-fd arrives at the SMTP sink" {
  wait_for_file_match "$MAILLOG" 'Subject: Bacula: Backup OK of server01-fd' 30
}

@test "the backup.sh summary arrives at the SMTP sink" {
  wait_for_file_match "$MAILLOG" 'Backup completed for server01' 30
}
