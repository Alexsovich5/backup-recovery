#!/bin/bash
#
# Copies the Bacula volumes, bootstrap files and catalog dump to the
# offsite host with rsync.
#
# Usage: offsite-sync.sh [--dest rsync://bacula@offsite/bacula]
#
#   $VOLUME_DIR/            -> <dest>/volumes/
#   $BACULA_WORKDIR/*.bsr   -> <dest>/bsr/
#   $BACULA_WORKDIR/bacula.sql -> <dest>/db/
#
# Run as the RunAfterJob step of the BackupCatalog job. The three copies
# run in that order and the script stops at the first one that fails.
#
# The rsync daemon module requires a login; rsync reads the password from
# $OFFSITE_PASSWORD_FILE (one line, mode 0600), so it never appears on a
# command line or in a log.
#
# Settings are read from $BACKUP_CONF (default /etc/bacula/backup.conf)
# when that file exists. Defaults: BACULA_WORKDIR=/var/lib/bacula,
# VOLUME_DIR=$BACULA_WORKDIR/volumes,
# OFFSITE_DEST=rsync://bacula@offsite/bacula,
# OFFSITE_PASSWORD_FILE=/etc/bacula/offsite.passwd.
#
# Exit codes:
#   0  everything copied
#   2  usage error, or the password file is not readable
#   otherwise the exit code of the rsync call that failed

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BACKUP_CONF="${BACKUP_CONF:-/etc/bacula/backup.conf}"
if [ -f "$BACKUP_CONF" ]; then
    . "$BACKUP_CONF"
fi

: "${LOG_FILE:=/var/log/backup-automation.log}"
: "${BACULA_WORKDIR:=/var/lib/bacula}"
: "${VOLUME_DIR:=$BACULA_WORKDIR/volumes}"
: "${OFFSITE_DEST:=rsync://bacula@offsite/bacula}"
: "${OFFSITE_PASSWORD_FILE:=/etc/bacula/offsite.passwd}"

. "$SCRIPT_DIR/lib/common.sh"

usage() {
    echo "Usage: $0 [--dest rsync://host/module]" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dest)
            [ -n "$2" ] || usage
            OFFSITE_DEST=$2
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

DEST="${OFFSITE_DEST%/}"

[ -f "$OFFSITE_PASSWORD_FILE" ] && [ -r "$OFFSITE_PASSWORD_FILE" ] \
    || die 2 "rsync password file not readable: $OFFSITE_PASSWORD_FILE"

# sync WHAT SOURCE... TARGET
# Runs rsync -a SOURCE... TARGET and exits with rsync's status on failure.
sync() {
    local what=$1 rc
    shift
    rsync -a --password-file="$OFFSITE_PASSWORD_FILE" "$@"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        die "$rc" "rsync of $what to $DEST failed with exit $rc"
    fi
    log_message "Copied $what to $DEST"
}

sync volumes "$VOLUME_DIR/" "$DEST/volumes/"
sync "bootstrap files" "$BACULA_WORKDIR"/*.bsr "$DEST/bsr/"
sync "catalog dump" "$BACULA_WORKDIR/bacula.sql" "$DEST/db/"
exit 0
