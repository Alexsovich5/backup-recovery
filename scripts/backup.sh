#!/bin/bash
#
# Runs an on-demand Bacula backup job and waits for its real result.
#
# Usage: backup.sh <client> <full|incremental|differential> [--no-verify]
#
# Runs the job "<client>-<type>", waits until it finishes and checks its
# JobStatus in the catalog. Unless --no-verify is given, it then runs
# "Verify-<client>" the same way.
#
# Settings are read from $BACKUP_CONF (default /etc/bacula/backup.conf, see
# config/backup.conf.example) when that file exists.
#
# Exit codes:
#   0  job ended in T (and the verify job too)
#   1  job was not queued or did not end in T
#   2  usage error
#   3  Director unreachable
#   4  verify job was not queued or did not end in T

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BACKUP_CONF="${BACKUP_CONF:-/etc/bacula/backup.conf}"
if [ -f "$BACKUP_CONF" ]; then
    . "$BACKUP_CONF"
fi

: "${LOG_FILE:=/var/log/backup-automation.log}"
: "${VOLUME_DIR:=/var/lib/bacula/volumes}"
: "${MIN_FREE_KB:=1048576}"

. "$SCRIPT_DIR/lib/common.sh"

usage() {
    echo "Usage: $0 <client> <full|incremental|differential> [--no-verify]" >&2
    exit 2
}

# run_and_wait JOB
# Queues JOB and waits for it. Prints its final JobStatus; returns 1 when
# the job was not queued or did not reach a terminal status.
run_and_wait() {
    local out jobid
    out=$(bconsole_cmd "run job=\"$1\" yes")
    jobid=$(printf '%s\n' "$out" | parse_jobid) || return 1
    log_message "Queued $1 as JobId $jobid"
    wait_job "$jobid"
}

# check_free_space
# Logs a WARNING when $VOLUME_DIR has less than $MIN_FREE_KB KiB free.
check_free_space() {
    local avail
    avail=$(df -Pk "$VOLUME_DIR" 2>/dev/null | awk 'NR == 2 { print $4 }')
    if [ -z "$avail" ]; then
        log_message "WARNING: cannot read free space on $VOLUME_DIR"
    elif [ "$avail" -lt "$MIN_FREE_KB" ]; then
        log_message "WARNING: low free space on $VOLUME_DIR: ${avail} KiB available, ${MIN_FREE_KB} KiB wanted"
    fi
}

VERIFY=yes
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-verify) VERIFY=no ;;
        -*) usage ;;
        *) ARGS+=("$arg") ;;
    esac
done
[ "${#ARGS[@]}" -eq 2 ] || usage

CLIENT="${ARGS[0]}"
BACKUP_TYPE="${ARGS[1]}"

case "$BACKUP_TYPE" in
    full|incremental|differential) ;;
    *)
        echo "$0: invalid backup type '$BACKUP_TYPE'" >&2
        usage
        ;;
esac

JOB_NAME="${CLIENT}-${BACKUP_TYPE}"
VERIFY_JOB="Verify-${CLIENT}"

log_message "Starting $BACKUP_TYPE backup for client: $CLIENT"

director_up || die 3 "Bacula Director not reachable through bconsole"

check_free_space

log_message "Executing Bacula job: $JOB_NAME"
status=$(run_and_wait "$JOB_NAME") || die 1 "Backup job $JOB_NAME was not queued or did not finish"
[ "$status" = "T" ] || die 1 "Backup job $JOB_NAME ended with status $status"
log_message "Backup job completed successfully: $JOB_NAME"

if [ "$VERIFY" = yes ]; then
    log_message "Running backup verification: $VERIFY_JOB"
    status=$(run_and_wait "$VERIFY_JOB") || die 4 "Verify job $VERIFY_JOB was not queued or did not finish"
    [ "$status" = "T" ] || die 4 "Verify job $VERIFY_JOB ended with status $status"
    log_message "Backup verification completed successfully"
fi

log_message "Backup process completed for $CLIENT"
exit 0
