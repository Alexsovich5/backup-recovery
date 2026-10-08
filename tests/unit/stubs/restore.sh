#!/bin/bash
#
# Stand-in for scripts/restore.sh in unit tests of restore-test.sh.
#
# Writes its arguments (space separated, one line) to $RESTORE_STUB_ARGS,
# then copies the contents of $RESTORE_STUB_TREE (a tree laid out like the
# client's absolute paths) under the --where prefix, as a Bacula restore
# with where=DIR would. Exits $RESTORE_STUB_EXIT (default 0) without
# copying anything when that is not 0.

echo "$*" > "${RESTORE_STUB_ARGS:-/dev/null}"

where=/tmp/bacula-restores
while [ "$#" -gt 0 ]; do
    case "$1" in
        --where) where=$2; shift 2 ;;
        *) shift ;;
    esac
done

[ "${RESTORE_STUB_EXIT:-0}" -eq 0 ] || exit "$RESTORE_STUB_EXIT"

mkdir -p "$where"
cp -a "$RESTORE_STUB_TREE/." "$where/"
echo "JobId 42"
