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

log "waiting for the catalog on $DB_HOST"
for i in $(seq 120); do
    if mysql -h "$DB_HOST" -u bacula -p"$DB_PASSWORD" -N -B bacula \
         -e 'SELECT VersionId FROM Version' > /dev/null 2>&1; then
        break
    fi
    sleep 1
done
mysql -h "$DB_HOST" -u bacula -p"$DB_PASSWORD" -N -B bacula -e 'SELECT VersionId FROM Version' > /dev/null

bacula-sd -c /etc/bacula/bacula-sd.conf
bacula-fd -c /etc/bacula/bacula-fd.conf

log "starting bacula-dir"
exec bacula-dir -f -c /etc/bacula/bacula-dir.conf
