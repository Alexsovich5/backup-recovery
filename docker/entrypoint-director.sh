#!/bin/bash
#
# Entrypoint of the "director" service: renders the Director, Storage
# Daemon, File Daemon (client backup-fd) and bconsole configs into
# /etc/bacula/ (where make_catalog_backup.pl and dbcheck look for them),
# waits for the catalog, starts bacula-sd and bacula-fd and then runs
# bacula-dir in the foreground.

set -e

set -a
. /src/config/bacula.env
set +a

log() { echo "entrypoint-director: $*"; }

render() {
    /src/scripts/render-config.sh "/src/config/$1" "/etc/bacula/$2"
}

render bacula-dir.conf bacula-dir.conf
render bacula-sd.conf bacula-sd.conf
render bacula-fd-director.conf bacula-fd.conf
render bconsole.conf bconsole.conf

mkdir -p /var/run/bacula /var/lib/bacula/volumes /var/log/bacula

# Credentials for the mysql client and for rsync to the offsite host go
# into root-only files, never onto a command line.
(
    umask 077
    printf '[client]\nuser=bacula\npassword=%s\n' "$DB_PASSWORD" > /etc/bacula/catalog.cnf
    printf '%s\n' "$OFFSITE_PASSWORD" > /etc/bacula/offsite.passwd
)

catalog_ready() {
    mysql --defaults-extra-file=/etc/bacula/catalog.cnf -h "$DB_HOST" -N -B bacula \
        -e 'SELECT VersionId FROM Version' > /dev/null
}

log "waiting for the catalog on $DB_HOST"
for i in $(seq 120); do
    catalog_ready 2> /dev/null && break
    sleep 1
done
catalog_ready

bacula-sd -c /etc/bacula/bacula-sd.conf
bacula-fd -c /etc/bacula/bacula-fd.conf

log "starting bacula-dir"
exec bacula-dir -f -c /etc/bacula/bacula-dir.conf
