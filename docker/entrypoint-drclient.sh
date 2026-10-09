#!/bin/bash
#
# Entrypoint of the "dr-client" service: the recovery host of the
# disaster-recovery drill, standing in for the offline key safe. The
# service is behind the "drill" compose profile and sits on the drill
# network only.
#
# - It generates the master recovery keypair into the keysafe volume
#   (/etc/bacula/keysafe) when that is empty. The volume is mounted into
#   this service only, so the master private key exists nowhere else.
# - It publishes master.cert (public) into the masterpub volume, from
#   which server01 takes it as its "PKI Master Key".
# - Without an argument it then runs drill-fd
#   (config/drill/bacula-fd-drill.conf) with the master keypair, so the
#   drill can restore and decrypt the offsite copy here. With the argument
#   "init" it stops after publishing the certificate ("make keys").
#
# The key directory and its files are checked before anything is chowned,
# chmodded or copied: a symlink or a file owned by another user stops the
# start-up. The only password this service receives is DRFD_PASSWORD.
#
# KEYSAFE_DIR overrides the key directory (used by the unit tests).

set -e

SRC=$(cd "$(dirname "$0")/.." && pwd)
. "$SRC/scripts/lib/keys.sh"

KEYSAFE=${KEYSAFE_DIR:-/etc/bacula/keysafe}
KEY_FILES="master.key master.pem master.cert"
MASTERPUB=${MASTERPUB_DIR:-/masterpub}

log() { echo "entrypoint-drclient: $*"; }

owners="0 $(id -u bacula)"
# shellcheck disable=SC2086
keydir_check "$KEYSAFE" "$owners" $KEY_FILES || { log "ERROR: refusing to use $KEYSAFE" >&2; exit 1; }

if [ ! -f "$KEYSAFE/master.pem" ]; then
    log "generating the master recovery keypair in $KEYSAFE"
    "$SRC/scripts/gen-keys.sh" --master "$KEYSAFE"
fi
chown -R bacula:bacula "$KEYSAFE"
chmod 0700 "$KEYSAFE"
chmod 0400 "$KEYSAFE/master.key" "$KEYSAFE/master.pem"
chmod 0444 "$KEYSAFE/master.cert"
# shellcheck disable=SC2086
keydir_check "$KEYSAFE" "$owners" $KEY_FILES || { log "ERROR: $KEYSAFE changed while it was being prepared" >&2; exit 1; }

mkdir -p "$MASTERPUB"
install -m 0444 "$KEYSAFE/master.cert" "$MASTERPUB/master.cert.tmp"
mv -f "$MASTERPUB/master.cert.tmp" "$MASTERPUB/master.cert"
log "published master.cert"

if [ "$1" = init ]; then
    exit 0
fi

set -a
. "$SRC/config/bacula.env"
. "${SECRETS_DIR:-/run/secrets}/dr-client"
KEY_DIR=$KEYSAFE
set +a

"$SRC/scripts/render-config.sh" "$SRC/config/drill/bacula-fd-drill.conf" /etc/bacula/bacula-fd.conf

mkdir -p /var/run/bacula /var/lib/bacula /drill-restores
exec bacula-fd -f -c /etc/bacula/bacula-fd.conf
