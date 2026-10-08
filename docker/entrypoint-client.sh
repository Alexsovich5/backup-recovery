#!/bin/bash
#
# Entrypoint of the "server01" service: the backed-up client. Renders the
# File Daemon config into /etc/bacula/, generates the PKI keys into the
# keys volume on first start, seeds /srv/data from
# tests/fixtures/data/ when the volume is empty and runs bacula-fd in the
# foreground.

set -e

set -a
. /src/config/bacula.env
KEY_DIR=/etc/bacula/keys
set +a

if [ ! -f "$KEY_DIR/server01.pem" ]; then
    echo "entrypoint-client: generating PKI keys in $KEY_DIR"
    /src/scripts/gen-keys.sh "$KEY_DIR" server01
fi

/src/scripts/render-config.sh /src/config/bacula-fd.conf /etc/bacula/bacula-fd.conf

mkdir -p /var/run/bacula /var/lib/bacula /srv/data /restores
if [ -z "$(ls -A /srv/data)" ]; then
    echo "entrypoint-client: seeding /srv/data from tests/fixtures/data"
    cp -a /src/tests/fixtures/data/. /srv/data/
fi

exec bacula-fd -f -c /etc/bacula/bacula-fd.conf
