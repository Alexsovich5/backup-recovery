#!/bin/bash
#
# Restore test: restores a client's newest backup into a scratch
# directory with restore.sh and checks the restored files against an
# md5sum manifest taken at backup time (see make-manifest.sh).
#
# Usage: restore-test.sh --client <client> --manifest FILE [--where DIR]
#                        [--root /srv/data]
#
#   --client    client whose backup is restored (passed to restore.sh)
#   --manifest  md5sum manifest with paths relative to --root
#   --where     restore prefix on the client (default /restores/restore-test);
#               it must be visible locally at the same path
#   --root      backed-up directory the manifest describes (default /srv/data);
#               the files are checked under DIR/<root>
#
# Every file named in the manifest is removed from DIR/<root> before the
# restore, so a copy left by an earlier run cannot pass the check.
#
# Settings are read from $BACKUP_CONF (default /etc/bacula/backup.conf)
# when that file exists. $RESTORE_SH overrides the restore command.
#
# Exit codes:
#   0  restore ended in T and every checksum matches
#   1  restore failed, or a file is missing or differs
#   2  usage error (including a missing or unreadable manifest)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BACKUP_CONF="${BACKUP_CONF:-/etc/bacula/backup.conf}"
if [ -f "$BACKUP_CONF" ]; then
    . "$BACKUP_CONF"
fi

: "${LOG_FILE:=/var/log/backup-automation.log}"
: "${RESTORE_SH:=$SCRIPT_DIR/restore.sh}"

. "$SCRIPT_DIR/lib/common.sh"

usage() {
    [ -n "$1" ] && echo "$0: $1" >&2
    cat >&2 <<USAGE
Usage: $0 --client <client> --manifest FILE [--where DIR] [--root /srv/data]
USAGE
    exit 2
}

CLIENT=
MANIFEST=
WHERE=/restores/restore-test
ROOT_DIR=/srv/data

while [ "$#" -gt 0 ]; do
    case "$1" in
        --client|--manifest|--where|--root)
            [ "$#" -ge 2 ] && [ -n "$2" ] || usage "$1 needs a value"
            case "$1" in
                --client) CLIENT=$2 ;;
                --manifest) MANIFEST=$2 ;;
                --where) WHERE=$2 ;;
                --root) ROOT_DIR=$2 ;;
            esac
            shift 2
            ;;
        *) usage "unknown argument '$1'" ;;
    esac
done

[ -n "$CLIENT" ] || usage "--client is required"
[ -n "$MANIFEST" ] || usage "--manifest is required"
[ -f "$MANIFEST" ] && [ -r "$MANIFEST" ] || usage "manifest not readable: $MANIFEST"
case "$WHERE" in
    /*) ;;
    *) usage "--where must be an absolute path" ;;
esac
[ "${WHERE%/}" != "" ] || usage "--where / would restore over the live files"
case "$ROOT_DIR" in
    /*) ;;
    *) usage "--root must be an absolute path" ;;
esac

case "$MANIFEST" in
    /*) ;;
    *) MANIFEST="$(pwd)/$MANIFEST" ;;
esac

WHERE=${WHERE%/}
CHECK_DIR="$WHERE${ROOT_DIR%/}"

total=$(grep -c . "$MANIFEST")
[ "$total" -gt 0 ] || die 1 "manifest lists no files: $MANIFEST"

# Clear earlier copies of the files under test. md5sum output has the
# path from column 35 on ("<32 hex>  <path>").
if [ -d "$CHECK_DIR" ]; then
    cut -c35- "$MANIFEST" | while IFS= read -r rel; do
        [ -n "$rel" ] && rm -f -- "$CHECK_DIR/$rel"
    done
fi

log_message "Restore test of $CLIENT into $WHERE, checking $CHECK_DIR"
"$RESTORE_SH" --client "$CLIENT" --where "$WHERE" \
    || die 1 "Restore of $CLIENT into $WHERE failed"

[ -d "$CHECK_DIR" ] || die 1 "Restore did not create $CHECK_DIR"

out=$(cd "$CHECK_DIR" && md5sum -c "$MANIFEST" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | grep -v ': OK$'
    failed=$(printf '%s\n' "$out" | grep -c ': FAILED')
    die 1 "Restore test of $CLIENT: $failed of $total files missing or different"
fi

log_message "Restore test of $CLIENT passed"
echo "$total files verified"
exit 0
