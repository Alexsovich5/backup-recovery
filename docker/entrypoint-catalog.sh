#!/bin/bash
#
# Entrypoint of the "catalog" service: runs MySQL 5.5 listening on the
# compose network and, on first start, creates the Bacula catalog.
#
# - database "bacula", created with Bacula's own make_mysql_tables
# - user bacula@'%' (password DB_PASSWORD from config/bacula.env) with all
#   rights on bacula.* and on bacula_drill.* (scratch catalog of the DR
#   drill, which the user may create and drop)

set -e

set -a
. /src/config/bacula.env
set +a

DATADIR=/var/lib/mysql

log() { echo "entrypoint-catalog: $*"; }

if [ ! -d "$DATADIR/mysql" ]; then
    log "initialising $DATADIR"
    mysql_install_db --user=mysql --datadir="$DATADIR" > /dev/null
fi

mkdir -p /var/run/mysqld
chown mysql:mysql /var/run/mysqld

mysqld --user=mysql --datadir="$DATADIR" --bind-address=0.0.0.0 \
    --skip-name-resolve --innodb-buffer-pool-size=32M \
    --performance-schema=0 &
pid=$!
trap 'kill -TERM $pid; wait $pid' TERM INT

for i in $(seq 60); do
    mysqladmin -u root ping > /dev/null 2>&1 && break
    kill -0 "$pid" 2>/dev/null || { log "mysqld exited"; exit 1; }
    sleep 1
done
mysqladmin -u root ping > /dev/null

if [ -z "$(mysql -u root -N -B -e "SHOW DATABASES LIKE 'bacula'")" ]; then
    log "creating database bacula and user bacula"
    # Quote the password as an SQL string literal.
    pw=${DB_PASSWORD//\\/\\\\}
    pw=${pw//\'/\\\'}
    # root only from inside this container; no anonymous accounts.
    mysql -u root <<SQL
DELETE FROM mysql.user WHERE User = '';
DELETE FROM mysql.user WHERE User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
CREATE DATABASE bacula;
GRANT ALL PRIVILEGES ON bacula.* TO 'bacula'@'%' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON bacula_drill.* TO 'bacula'@'%';
FLUSH PRIVILEGES;
SQL
    log "creating Bacula tables"
    db_name=bacula /usr/share/bacula-director/make_mysql_tables -u root
fi

log "catalog ready"
wait "$pid"
