#!/bin/bash
#
# Writes an md5sum manifest of every regular file under a directory.
#
# Usage: make-manifest.sh <dir> <out>
#
# Paths in <out> are relative to <dir> and sorted, so the manifest can be
# checked with "cd <restored dir> && md5sum -c <out>".
#
# Exit codes:
#   0  manifest written
#   1  <dir> missing or md5sum failed
#   2  usage error

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <dir> <out>" >&2
    exit 2
fi

DIR=$1
OUT=$2

if [ ! -d "$DIR" ]; then
    echo "$0: not a directory: $DIR" >&2
    exit 1
fi

case "$OUT" in
    /*) ;;
    *) OUT="$(pwd)/$OUT" ;;
esac

set -o pipefail
(cd "$DIR" && find . -type f -printf '%P\0' | LC_ALL=C sort -z \
    | xargs -0 -r md5sum) > "$OUT" || exit 1
