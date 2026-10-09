#!/bin/bash
#
# split-secrets.sh <passwords.env> <outdir>
#
# Writes one file per service into <outdir> (created mode 0700), each mode
# 0600 and holding only the passwords that service needs, as shell
# assignments that the service entrypoint sources from /run/secrets:
#
#   catalog.env    DB_PASSWORD DRILL_DB_PASSWORD
#   director.env   DIR_PASSWORD FD_PASSWORD SD_PASSWORD DB_PASSWORD OFFSITE_PASSWORD
#   server01.env   FD_PASSWORD
#   offsite.env    OFFSITE_PASSWORD
#   dr-client.env  DRFD_PASSWORD
#   drill.env      DB_PASSWORD (the value of DRILL_DB_PASSWORD) DRFD_PASSWORD
#
# Nothing is written when a needed password is missing or empty. The
# passwords are never printed.
#
# Exit codes:
#   0  files written
#   1  a password is missing or empty
#   2  usage error or unreadable input

[ $# -eq 2 ] || { echo "usage: $0 <passwords.env> <outdir>" >&2; exit 2; }
src=$1
out=$2
[ -f "$src" ] && [ -r "$src" ] || { echo "split-secrets: cannot read $src" >&2; exit 2; }

# service:VAR[=SOURCE] ...  (DB_PASSWORD=DRILL_DB_PASSWORD takes its value
# from DRILL_DB_PASSWORD).
spec="
catalog:DB_PASSWORD,DRILL_DB_PASSWORD
director:DIR_PASSWORD,FD_PASSWORD,SD_PASSWORD,DB_PASSWORD,OFFSITE_PASSWORD
server01:FD_PASSWORD
offsite:OFFSITE_PASSWORD
dr-client:DRFD_PASSWORD
drill:DB_PASSWORD=DRILL_DB_PASSWORD,DRFD_PASSWORD
"

# Render every file in memory first so that nothing is written on error.
services=()
contents=()
for line in $spec; do
    content=
    IFS=, read -ra vars <<< "${line#*:}"
    for item in "${vars[@]}"; do
        name=${item%%=*}
        from=${item#*=}
        value=$(. "$src" > /dev/null 2>&1; printf '%s' "${!from}")
        if [ -z "$value" ]; then
            echo "split-secrets: $from is missing or empty in $src" >&2
            exit 1
        fi
        content+=$(printf '%s=%q' "$name" "$value")$'\n'
    done
    services+=("${line%%:*}")
    contents+=("$content")
done

umask 077
mkdir -p "$out" || exit 2
chmod 0700 "$out"
for i in "${!services[@]}"; do
    printf '%s' "${contents[$i]}" > "$out/${services[$i]}.env.tmp"
    chmod 0600 "$out/${services[$i]}.env.tmp"
    mv -f "$out/${services[$i]}.env.tmp" "$out/${services[$i]}.env"
done
echo "wrote ${#services[@]} secret files to $out"
