#!/bin/bash
#
# Disaster-recovery drill: shows that the offsite copy plus the master
# recovery key are enough to get client data back, without the live
# Director, Storage Daemon or catalog.
#
# Usage: dr-drill.sh --offsite DIR --manifest FILE --keys DIR
#                    [--db-host H] [--root /srv/data]
#
#   --offsite   offsite copy: DIR/volumes/, DIR/bsr/, DIR/db/bacula.sql
#   --manifest  md5sum manifest of the client data (make-manifest.sh)
#   --keys      directory holding master.key and master.cert
#   --db-host   MySQL host for the scratch catalog (default $DB_HOST, or
#               "catalog")
#   --root      backed-up directory the manifest describes (default
#               /srv/data)
#
# Steps:
#   1. bextract -b DIR/bsr/BackupCatalog.bsr recovers bacula.sql from a
#      scratch copy of the offsite volumes; it must equal DIR/db/bacula.sql.
#   2. The dump is loaded into the scratch database bacula_drill, which
#      must hold at least one successful backup of server01-fd.
#   3. drill-dir, drill-sd and drill-fd (config/drill/, ports 9201-9203 on
#      127.0.0.1) start on that catalog; drill-fd's only key is master.pem,
#      built from master.key and master.cert.
#   4. server01-fd's newest backup is restored to drill-fd under the
#      scratch directory and checked with md5sum -c against the manifest.
# Whatever happens, the drill daemons are stopped, bacula_drill is dropped
# and the scratch directory is removed on exit.
#
# Settings are read from $BACKUP_CONF (default /etc/bacula/backup.conf)
# when that file exists. DB_PASSWORD (and DB_HOST) come from the
# environment or, when DB_PASSWORD is unset, from config/bacula.env. The
# catalog user is $DB_USER (default bacula). Scratch directories are made
# under $DRILL_TMPDIR (default /var/tmp). $RESTORE_SH overrides the restore
# command; $DRILL_START_TIMEOUT (default 60) is how long to wait for
# drill-dir to answer.
#
# Exit codes:
#   0  every step passed
#   1  a step failed
#   2  usage error

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BACKUP_CONF="${BACKUP_CONF:-/etc/bacula/backup.conf}"
if [ -f "$BACKUP_CONF" ]; then
    . "$BACKUP_CONF"
fi

if [ -z "$DB_PASSWORD" ] && [ -f "$SCRIPT_DIR/../config/bacula.env" ]; then
    DB_PASSWORD=$(. "$SCRIPT_DIR/../config/bacula.env"; echo "$DB_PASSWORD")
    [ -n "$DB_HOST" ] || DB_HOST=$(. "$SCRIPT_DIR/../config/bacula.env"; echo "$DB_HOST")
fi

: "${LOG_FILE:=/var/log/backup-automation.log}"
: "${DB_USER:=bacula}"
: "${DRILL_TMPDIR:=/var/tmp}"
: "${DRILL_START_TIMEOUT:=60}"
: "${RESTORE_SH:=$SCRIPT_DIR/restore.sh}"
DRILL_CONFIG_DIR="$SCRIPT_DIR/../config/drill"
DRILL_DB=bacula_drill

. "$SCRIPT_DIR/lib/common.sh"

usage() {
    [ -n "$1" ] && echo "$0: $1" >&2
    cat >&2 <<USAGE
Usage: $0 --offsite DIR --manifest FILE --keys DIR [--db-host H] [--root /srv/data]
USAGE
    exit 2
}

OFFSITE=
MANIFEST=
KEYS=
DB_HOST_ARG=
ROOT_DIR=/srv/data

while [ "$#" -gt 0 ]; do
    case "$1" in
        --offsite|--manifest|--keys|--db-host|--root)
            [ "$#" -ge 2 ] && [ -n "$2" ] || usage "$1 needs a value"
            case "$1" in
                --offsite) OFFSITE=$2 ;;
                --manifest) MANIFEST=$2 ;;
                --keys) KEYS=$2 ;;
                --db-host) DB_HOST_ARG=$2 ;;
                --root) ROOT_DIR=$2 ;;
            esac
            shift 2
            ;;
        *) usage "unknown argument '$1'" ;;
    esac
done

[ -n "$OFFSITE" ] || usage "--offsite is required"
[ -n "$MANIFEST" ] || usage "--manifest is required"
[ -n "$KEYS" ] || usage "--keys is required"
[ -d "$OFFSITE" ] || usage "offsite directory not found: $OFFSITE"
[ -d "$KEYS" ] || usage "key directory not found: $KEYS"
[ -f "$MANIFEST" ] && [ -r "$MANIFEST" ] || usage "manifest not readable: $MANIFEST"
case "$ROOT_DIR" in
    /*) ;;
    *) usage "--root must be an absolute path" ;;
esac
[ -n "$DB_PASSWORD" ] || usage "DB_PASSWORD is not set"

case "$MANIFEST" in
    /*) ;;
    *) MANIFEST="$(pwd)/$MANIFEST" ;;
esac
OFFSITE=${OFFSITE%/}
DB_HOST=${DB_HOST_ARG:-${DB_HOST:-catalog}}

umask 077
SCRATCH=$(mktemp -d "${DRILL_TMPDIR%/}/dr-drill.XXXXXX") \
    || die 1 "cannot create a scratch directory under $DRILL_TMPDIR"
DAEMON_PIDS=

# Stops the drill daemons, drops the scratch catalog and removes the
# scratch directory. Runs on every exit.
cleanup() {
    local rc=$? pid
    for pid in $DAEMON_PIDS; do
        kill -TERM "$pid" 2>/dev/null
    done
    for pid in $DAEMON_PIDS; do
        wait "$pid" 2>/dev/null
    done
    drill_mysql -e "DROP DATABASE IF EXISTS $DRILL_DB" \
        || log_message "WARNING: could not drop database $DRILL_DB"
    rm -rf "$SCRATCH"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

# The password goes into an option file, not onto the command line.
printf '[client]\nuser=%s\npassword=%s\n' "$DB_USER" "$DB_PASSWORD" > "$SCRATCH/my.cnf"

# drill_mysql ARGS...
# Runs the mysql client against the catalog host.
drill_mysql() {
    mysql --defaults-extra-file="$SCRATCH/my.cnf" -h "$DB_HOST" "$@"
}

for f in bsr/BackupCatalog.bsr db/bacula.sql; do
    [ -s "$OFFSITE/$f" ] || die 1 "offsite copy has no $f"
done
[ -d "$OFFSITE/volumes" ] || die 1 "offsite copy has no volumes/"
for f in master.key master.cert; do
    [ -r "$KEYS/$f" ] || die 1 "no readable $KEYS/$f"
done

# Render the drill configs into the scratch directory.
mkdir -p "$SCRATCH/work" "$SCRATCH/volumes" "$SCRATCH/extract" "$SCRATCH/restore" \
    || die 1 "cannot populate $SCRATCH"
DRILL_PASSWORD=$(head -c 32 /dev/urandom | md5sum | cut -c1-32)
for c in bacula-dir-drill bacula-sd-drill bacula-fd-drill; do
    DRILL_DIR=$SCRATCH DRILL_PASSWORD=$DRILL_PASSWORD DB_HOST=$DB_HOST \
        DB_PASSWORD=$DB_PASSWORD \
        "$SCRIPT_DIR/render-config.sh" "$DRILL_CONFIG_DIR/$c.conf" "$SCRATCH/$c.conf" \
        || die 1 "cannot render $c.conf"
done
printf 'Director {\n  Name = drill-dir\n  DIRport = 9201\n  Address = 127.0.0.1\n  Password = "%s"\n}\n' \
    "$DRILL_PASSWORD" > "$SCRATCH/bconsole-drill.conf"

# 1. Recover the catalog dump from the volumes with bextract alone.
log_message "DR drill: copying offsite volumes to $SCRATCH/volumes"
cp -a "$OFFSITE/volumes/." "$SCRATCH/volumes/" || die 1 "cannot copy the offsite volumes"

log_message "DR drill: extracting the catalog dump with bextract"
bextract -c "$SCRATCH/bacula-sd-drill.conf" -b "$OFFSITE/bsr/BackupCatalog.bsr" \
    FileStorage "$SCRATCH/extract" > "$SCRATCH/bextract.log" 2>&1 || {
    cat "$SCRATCH/bextract.log" >&2
    die 1 "bextract could not recover the catalog dump"
}
DUMP="$SCRATCH/extract/var/lib/bacula/bacula.sql"
[ -s "$DUMP" ] || die 1 "bextract did not recover var/lib/bacula/bacula.sql"
cmp -s "$DUMP" "$OFFSITE/db/bacula.sql" \
    || die 1 "recovered bacula.sql differs from $OFFSITE/db/bacula.sql"
echo "catalog dump recovered from volume: OK"

# 2. Load it into the scratch catalog and check it knows server01's backups.
log_message "DR drill: loading the dump into $DRILL_DB on $DB_HOST"
drill_mysql -e "DROP DATABASE IF EXISTS $DRILL_DB; CREATE DATABASE $DRILL_DB" \
    || die 1 "cannot create database $DRILL_DB"
drill_mysql "$DRILL_DB" < "$DUMP" || die 1 "loading the dump into $DRILL_DB failed"
jobs=$(drill_mysql -N -B -e "SELECT COUNT(*) FROM Job j JOIN Client c ON c.ClientId = j.ClientId WHERE c.Name = 'server01-fd' AND j.Type='B' AND j.JobStatus='T'" "$DRILL_DB") \
    || die 1 "cannot query $DRILL_DB"
echo "catalog jobs: $jobs"
[[ "$jobs" =~ ^[0-9]+$ ]] && [ "$jobs" -ge 1 ] \
    || die 1 "the recovered catalog holds no successful server01-fd backup"

# 3. Start the scratch daemons; drill-fd's keypair is the master key.
cat "$KEYS/master.key" "$KEYS/master.cert" > "$SCRATCH/master.pem" \
    || die 1 "cannot build master.pem"
chmod 0600 "$SCRATCH/master.pem"

# start_daemon NAME
# Runs NAME (bacula-sd, bacula-fd or bacula-dir) with -f on its drill
# config as a background job and records its pid for cleanup.
start_daemon() {
    "$1" -f -c "$SCRATCH/$1-drill.conf" > "$SCRATCH/$1.out" 2>&1 &
    DAEMON_PIDS="$DAEMON_PIDS $!"
}
log_message "DR drill: starting drill-sd, drill-fd and drill-dir"
start_daemon bacula-sd
start_daemon bacula-fd
start_daemon bacula-dir

export BCONSOLE_CONF="$SCRATCH/bconsole-drill.conf"
waited=0
until director_up; do
    for pid in $DAEMON_PIDS; do
        kill -0 "$pid" 2>/dev/null || {
            cat "$SCRATCH"/bacula-*.out >&2
            die 1 "a drill daemon exited during start-up"
        }
    done
    if [ "$waited" -ge "$DRILL_START_TIMEOUT" ]; then
        cat "$SCRATCH"/bacula-*.out >&2
        die 1 "drill-dir did not answer within ${DRILL_START_TIMEOUT}s"
    fi
    sleep 1
    waited=$((waited + 1))
done

# 4. Restore server01's newest data to drill-fd and check it.
log_message "DR drill: restoring server01-fd to drill-fd under $SCRATCH/restore"
BACKUP_CONF="$SCRATCH/none.conf" BCONSOLE_CONF="$BCONSOLE_CONF" \
    "$RESTORE_SH" --client server01-fd --restore-client drill-fd --where "$SCRATCH/restore" || {
    [ -f "$SCRATCH/drill-dir.log" ] && tail -n 40 "$SCRATCH/drill-dir.log" >&2
    die 1 "restore through the drill daemons failed"
}

CHECK_DIR="$SCRATCH/restore${ROOT_DIR%/}"
[ -d "$CHECK_DIR" ] || die 1 "the restore did not create $CHECK_DIR"
total=$(grep -c . "$MANIFEST")
out=$(cd "$CHECK_DIR" && md5sum -c "$MANIFEST" 2>&1)
if [ $? -ne 0 ]; then
    printf '%s\n' "$out" | grep -v ': OK$'
    die 1 "restored files do not match the manifest"
fi
echo "files verified: $total"
log_message "DR drill passed: $jobs catalog jobs, $total files verified"
exit 0
