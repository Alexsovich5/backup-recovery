#!/bin/bash
#
# Restores a client's backed-up files without the interactive bconsole
# restore dialogue, then waits for the restore job and checks its status.
#
# Usage: restore.sh --client <client> [--where DIR]
#                   [--before 'YYYY-MM-DD HH:MM:SS'] [--jobid N]
#                   [--file PATH ...] [--restore-client FD] [--dry-run]
#
#   --client          client whose backups are restored; "server01" means
#                     the File Daemon "server01-fd"
#   --where           restore prefix on the target FD (default
#                     /tmp/bacula-restores; "/" restores in place)
#   --before          use the newest backups made before this time
#   --jobid           restore from this JobId instead
#   --file            restore only this path (repeatable); default all files
#   --restore-client  FD that receives the files (default the client's FD)
#   --dry-run         print the bconsole command and exit
#
# Client names must be plain Bacula names and paths may not contain double
# quotes or control characters, so no argument can end the restore command
# or add a second console command (exit 2).
#
# Settings are read from $BACKUP_CONF (default /etc/bacula/backup.conf)
# when that file exists.
#
# Exit codes:
#   0  restore job ended in T (or --dry-run)
#   1  restore was not queued or did not end in T
#   2  usage error
#   3  Director unreachable

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BACKUP_CONF="${BACKUP_CONF:-/etc/bacula/backup.conf}"
if [ -f "$BACKUP_CONF" ]; then
    . "$BACKUP_CONF"
fi

: "${LOG_FILE:=/var/log/backup-automation.log}"

. "$SCRIPT_DIR/lib/common.sh"

usage() {
    [ -n "$1" ] && echo "$0: $1" >&2
    cat >&2 <<USAGE
Usage: $0 --client <client> [--where DIR] [--before 'YYYY-MM-DD HH:MM:SS']
       [--jobid N] [--file PATH ...] [--restore-client FD] [--dry-run]
USAGE
    exit 2
}

# fd_name NAME
# Prints NAME with the "-fd" suffix that Bacula Client resources use.
fd_name() {
    case "$1" in
        *-fd) echo "$1" ;;
        *) echo "$1-fd" ;;
    esac
}

# arg KEY VALUE
# Prints KEY=VALUE for bconsole, quoting VALUE when it holds blanks.
arg() {
    case "$2" in
        *[[:space:]]*) printf '%s="%s"' "$1" "$2" ;;
        *) printf '%s=%s' "$1" "$2" ;;
    esac
}

CLIENT=
WHERE=/tmp/bacula-restores
BEFORE=
JOBID=
RESTORE_CLIENT=
DRY_RUN=no
FILES=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --client|--where|--before|--jobid|--file|--restore-client)
            [ "$#" -ge 2 ] && [ -n "$2" ] || usage "$1 needs a value"
            case "$1" in
                --client) CLIENT=$2 ;;
                --where) WHERE=$2 ;;
                --before) BEFORE=$2 ;;
                --jobid) JOBID=$2 ;;
                --file) FILES+=("$2") ;;
                --restore-client) RESTORE_CLIENT=$2 ;;
            esac
            shift 2
            ;;
        --dry-run) DRY_RUN=yes; shift ;;
        *) usage "unknown argument '$1'" ;;
    esac
done

[ -n "$CLIENT" ] || usage "--client is required"
bacula_name_ok "$CLIENT" || usage "invalid client name"
if [ -n "$RESTORE_CLIENT" ]; then
    bacula_name_ok "$RESTORE_CLIENT" || usage "invalid restore client name"
fi
case "$WHERE" in
    /*) ;;
    *) usage "--where must be an absolute path" ;;
esac
bconsole_arg_ok "$WHERE" || usage "--where holds a double quote or control character"
for f in "${FILES[@]+"${FILES[@]}"}"; do
    bconsole_arg_ok "$f" || usage "--file holds a double quote or control character"
done
if [ -n "$BEFORE" ]; then
    [[ "$BEFORE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] \
        || usage "--before must look like 'YYYY-MM-DD HH:MM:SS'"
fi
if [ -n "$JOBID" ]; then
    [[ "$JOBID" =~ ^[0-9]+$ ]] || usage "--jobid must be a number"
    [ -z "$BEFORE" ] || usage "--jobid and --before cannot be combined"
fi

CLIENT_FD=$(fd_name "$CLIENT")
RESTORE_FD=$(fd_name "${RESTORE_CLIENT:-$CLIENT}")

# Job selection: a JobId, the newest backups before a time, or the newest
# backups now. Selected files need no directory tree; everything else
# marks the whole tree.
CMD="restore $(arg client "$CLIENT_FD") $(arg restoreclient "$RESTORE_FD") $(arg where "$WHERE")"
if [ "${#FILES[@]}" -gt 0 ]; then
    [ -n "$JOBID" ] && CMD="$CMD jobid=$JOBID"
    [ -n "$BEFORE" ] && CMD="$CMD $(arg before "$BEFORE")"
    for f in "${FILES[@]}"; do
        CMD="$CMD $(arg file "$f")"
    done
    CMD="$CMD done yes"
elif [ -n "$JOBID" ]; then
    CMD="$CMD jobid=$JOBID all done yes"
elif [ -n "$BEFORE" ]; then
    CMD="$CMD select $(arg before "$BEFORE") all done yes"
else
    CMD="$CMD select current all done yes"
fi

if [ "$DRY_RUN" = yes ]; then
    echo "$CMD"
    exit 0
fi

log_message "Restoring $CLIENT_FD to $RESTORE_FD where=$WHERE"

director_up || die 3 "Bacula Director not reachable through bconsole"

out=$(bconsole_cmd "$CMD")
jobid=$(printf '%s\n' "$out" | parse_jobid) || {
    printf '%s\n' "$out" >&2
    die 1 "Restore of $CLIENT_FD was not queued"
}
log_message "Queued restore of $CLIENT_FD as JobId $jobid"

status=$(wait_job "$jobid") || die 1 "Restore JobId $jobid did not finish"
[ "$status" = "T" ] || die 1 "Restore JobId $jobid ended with status $status"

log_message "Restore JobId $jobid completed successfully"
echo "JobId $jobid"
exit 0
