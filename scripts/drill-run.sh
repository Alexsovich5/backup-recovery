#!/bin/bash
#
# Runs the disaster-recovery drill from the drill service: waits for
# drill-fd on the recovery host, writes a manifest of the live client data
# (read-only at $DRILL_DATA_DIR) and runs dr-drill.sh over the offsite copy
# with it. Extra arguments go to dr-drill.sh.
#
# Environment: DRFD_HOST (default dr-client), DRFD_PORT (9202),
# DRILL_FD_TIMEOUT seconds to wait for drill-fd (60), DRILL_DATA_DIR
# (/clientdata/server01), OFFSITE_DIR (/offsite), DR_DRILL_SH (dr-drill.sh
# beside this script).
#
# Exit codes: dr-drill.sh's, or 1 when drill-fd does not answer or the
# manifest cannot be made.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

: "${DRFD_HOST:=dr-client}"
: "${DRFD_PORT:=9202}"
: "${DRILL_FD_TIMEOUT:=60}"
: "${DRILL_DATA_DIR:=/clientdata/server01}"
: "${OFFSITE_DIR:=/offsite}"
: "${DR_DRILL_SH:=$SCRIPT_DIR/dr-drill.sh}"

waited=0
until (exec 3<> "/dev/tcp/$DRFD_HOST/$DRFD_PORT") 2>/dev/null; do
    [ "$waited" -lt "$DRILL_FD_TIMEOUT" ] \
        || die 1 "drill-fd on $DRFD_HOST:$DRFD_PORT did not answer within ${DRILL_FD_TIMEOUT}s (is dr-client up?)"
    sleep 1
    waited=$((waited + 1))
done

manifest=$(mktemp) || die 1 "cannot create a manifest file"
trap 'rm -f "$manifest"' EXIT
"$SCRIPT_DIR/make-manifest.sh" "$DRILL_DATA_DIR" "$manifest" \
    || die 1 "cannot make a manifest of $DRILL_DATA_DIR"

"$DR_DRILL_SH" --offsite "$OFFSITE_DIR" --manifest "$manifest" "$@"
