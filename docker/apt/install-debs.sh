#!/bin/bash
#
# install-debs.sh DIR
#
# Installs every .deb in DIR (the set verified by fetch-debs.sh) with
# dpkg. dpkg -i refuses to unpack a package whose Pre-Depends are not yet
# configured, so the packages that others in DIR pre-depend on are
# installed in an earlier pass. Exits non-zero if any dpkg call fails.

set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 DIR" >&2; exit 2; }
DIR=$1

declare -A file_of
for deb in "$DIR"/*.deb; do
    file_of[$(dpkg-deb -f "$deb" Package)]=$deb
done
[ "${#file_of[@]}" -gt 0 ] || { echo "install-debs: no packages in $DIR" >&2; exit 1; }

remaining=("${!file_of[@]}")
pass=0
while [ "${#remaining[@]}" -gt 0 ]; do
    pass=$((pass + 1))
    [ "$pass" -le 10 ] || { echo "install-debs: Pre-Depends do not resolve" >&2; exit 1; }

    # Packages still to install that another one left pre-depends on.
    declare -A left=() needed=()
    for p in "${remaining[@]}"; do
        left[$p]=1
    done
    for p in "${remaining[@]}"; do
        for dep in $(dpkg-deb -f "${file_of[$p]}" Pre-Depends | tr ',|' '\n\n' \
                     | sed -e 's/([^)]*)//g' -e 's/:any//' -e 's/[[:space:]]//g'); do
            if [ -n "${left[$dep]+set}" ] && [ "$dep" != "$p" ]; then
                needed[$dep]=1
            fi
        done
    done

    batch=()
    rest=()
    for p in "${remaining[@]}"; do
        if [ "${#needed[@]}" -gt 0 ] && [ -z "${needed[$p]+set}" ]; then
            rest+=("$p")
        else
            batch+=("${file_of[$p]}")
        fi
    done
    unset left needed

    echo "install-debs: pass $pass, ${#batch[@]} package(s)"
    dpkg -i "${batch[@]}"
    remaining=("${rest[@]+"${rest[@]}"}")
done
