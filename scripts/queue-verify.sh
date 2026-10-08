#!/bin/bash
#
# Queues the Verify job of a client and returns without waiting for it.
#
# Usage: queue-verify.sh <client>
#
# Sends "run job=Verify-<client> yes" to the Director. <client> may be a
# File Daemon name ("server01-fd"); the "-fd" suffix is dropped. Used by
# the Director-side RunScript of the scheduled backup job: 5.2.6 refuses a
# "run" console command inside a RunScript, so the job is queued through
# a separate bconsole session instead.
#
# Settings are read from $BACKUP_CONF (default /etc/bacula/backup.conf)
# when that file exists.
#
# Exit codes:
#   0  verify job queued
#   1  verify job was not queued
#   2  usage error

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BACKUP_CONF="${BACKUP_CONF:-/etc/bacula/backup.conf}"
if [ -f "$BACKUP_CONF" ]; then
    . "$BACKUP_CONF"
fi

: "${LOG_FILE:=/var/log/backup-automation.log}"

. "$SCRIPT_DIR/lib/common.sh"

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "Usage: $0 <client>" >&2
    exit 2
fi

VERIFY_JOB="Verify-${1%-fd}"

out=$(bconsole_cmd "run job=\"$VERIFY_JOB\" yes")
jobid=$(printf '%s\n' "$out" | parse_jobid) || {
    printf '%s\n' "$out" >&2
    die 1 "Verify job $VERIFY_JOB was not queued"
}
log_message "Queued $VERIFY_JOB as JobId $jobid"
exit 0
