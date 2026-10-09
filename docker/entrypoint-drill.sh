#!/bin/bash
#
# Entrypoint of the "drill" service: a throwaway container that runs the
# disaster-recovery drill ("make drill"). It is the only service on both
# the backup network (catalog, offsite copy) and the drill network
# (dr-client). It gets a secret file with two passwords: the account of the
# scratch catalog bacula_drill (as DB_PASSWORD) and DRFD_PASSWORD. It
# holds no key and no Director, Storage Daemon or File Daemon password.
# Runs the given command with them in its environment.

set -e

SRC=$(cd "$(dirname "$0")/.." && pwd)

set -a
. "$SRC/config/bacula.env"
. "${SECRETS_DIR:-/run/secrets}/drill"
set +a

mkdir -p /var/run/bacula /var/lib/bacula
exec "$@"
