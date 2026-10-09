#!/bin/bash
#
# Entrypoint of the "server01" service: the backed-up client. Generates
# the client's own PKI keypair into the keys volume on first start, copies
# the master recovery certificate (public part only) published by the
# dr-client service, renders the File Daemon config into /etc/bacula/,
# seeds /srv/data from tests/fixtures/data/ when the volume is empty and
# runs bacula-fd in the foreground.
#
# The master private key is never generated or stored here; start-up is
# refused if one is found in the key directory.

set -e

SRC=$(cd "$(dirname "$0")/.." && pwd)
. "$SRC/scripts/lib/keys.sh"

KEY_DIR=${CLIENT_KEY_DIR:-/etc/bacula/keys}

log() { echo "entrypoint-client: $*"; }

# Refuse symlinks and foreign owners before anything in the key directory
# is read, generated, chowned or chmodded.
keydir_check "$KEY_DIR" "0 $(id -u bacula)" server01.key server01.pem master.cert master.key master.pem \
    || { log "ERROR: refusing to use $KEY_DIR" >&2; exit 1; }

set -a
. "$SRC/config/bacula.env"
. "${SECRETS_DIR:-/run/secrets}/server01"
KEY_DIR=${CLIENT_KEY_DIR:-/etc/bacula/keys}
set +a

for f in master.key master.pem; do
    if [ -e "$KEY_DIR/$f" ]; then
        log "ERROR: $KEY_DIR/$f is master private key material; move it to the key safe" >&2
        exit 1
    fi
done

if [ ! -f "$KEY_DIR/server01.pem" ]; then
    log "generating the server01 keypair in $KEY_DIR"
    "$SRC/scripts/gen-keys.sh" --client "$KEY_DIR" server01
fi

for i in $(seq 120); do
    [ -s /masterpub/master.cert ] && break
    sleep 1
done
[ -s /masterpub/master.cert ] || { log "ERROR: no master.cert in /masterpub; run make keys first" >&2; exit 1; }
[ ! -L /masterpub/master.cert ] || { log "ERROR: /masterpub/master.cert is a symlink" >&2; exit 1; }
install -m 0444 /masterpub/master.cert "$KEY_DIR/master.cert"

chown -R bacula:bacula "$KEY_DIR"
chmod 0700 "$KEY_DIR"
chmod 0400 "$KEY_DIR/server01.key" "$KEY_DIR/server01.pem"

"$SRC/scripts/render-config.sh" "$SRC/config/bacula-fd.conf" /etc/bacula/bacula-fd.conf

mkdir -p /var/run/bacula /var/lib/bacula /srv/data /restores
if [ -z "$(ls -A /srv/data)" ]; then
    log "seeding /srv/data from tests/fixtures/data"
    cp -a /src/tests/fixtures/data/. /srv/data/
fi

exec bacula-fd -f -c /etc/bacula/bacula-fd.conf
