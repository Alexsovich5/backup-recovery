#!/bin/bash
#
# Entrypoint of the "dr-client" service: the recovery host of the
# disaster-recovery drill, standing in for the offline key safe.
#
# - On first start it generates the master recovery keypair into the
#   keysafe volume (/etc/bacula/keysafe). That volume is mounted into this
#   service only, so the master private key exists nowhere else.
# - It publishes master.cert (public) into the masterpub volume, from
#   which server01 takes it as its "PKI Master Key".
# - It runs drill-fd (config/drill/bacula-fd-drill.conf) with the master
#   keypair, so the drill can restore and decrypt the offsite copy here.

set -e

set -a
. /src/config/bacula.env
KEY_DIR=/etc/bacula/keysafe
set +a

log() { echo "entrypoint-drclient: $*"; }

if [ ! -f "$KEY_DIR/master.pem" ]; then
    log "generating the master recovery keypair in $KEY_DIR"
    /src/scripts/gen-keys.sh --master "$KEY_DIR"
fi
chown -R bacula:bacula "$KEY_DIR"
chmod 0700 "$KEY_DIR"
chmod 0400 "$KEY_DIR/master.key" "$KEY_DIR/master.pem"
chmod 0444 "$KEY_DIR/master.cert"

mkdir -p /masterpub
install -m 0444 "$KEY_DIR/master.cert" /masterpub/master.cert.tmp
mv -f /masterpub/master.cert.tmp /masterpub/master.cert
log "published master.cert"

/src/scripts/render-config.sh /src/config/drill/bacula-fd-drill.conf /etc/bacula/bacula-fd.conf

mkdir -p /var/run/bacula /var/lib/bacula /drill-restores
exec bacula-fd -f -c /etc/bacula/bacula-fd.conf
