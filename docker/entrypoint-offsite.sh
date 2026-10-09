#!/bin/bash
#
# Entrypoint of the "offsite" service: the simulated offsite host. Renders
# the rsync daemon config and runs rsync --daemon in the foreground over
# /offsite (named volume "offsite").

set -e

set -a
. /src/config/bacula.env
. "${SECRETS_DIR:-/run/secrets}/offsite"
set +a

/src/scripts/render-config.sh /src/config/rsyncd.conf /etc/rsyncd.conf
(umask 077; printf 'bacula:%s\n' "$OFFSITE_PASSWORD" > /etc/rsyncd.secrets)

mkdir -p /offsite
echo "entrypoint-offsite: starting rsync daemon, module bacula at /offsite"
exec rsync --daemon --no-detach --config=/etc/rsyncd.conf
