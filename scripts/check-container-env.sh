#!/bin/bash
#
# check-container-env.sh <secrets-dir> <container>...
#
# Fails when the environment of a container (as "docker inspect" shows it)
# carries a secret: a variable whose name contains PASSWORD, PASSWD, SECRET
# or TOKEN, or any variable whose value equals a password from the
# per-service files in <secrets-dir> (*.env, written by split-secrets.sh).
# Only variable names are printed, never values. $DOCKER overrides the
# docker command.
#
# Exit codes:
#   0  no container leaks a secret
#   1  a container leaks a secret
#   2  usage error

[ $# -ge 2 ] || { echo "usage: $0 <secrets-dir> <container>..." >&2; exit 2; }
dir=$1
shift
: "${DOCKER:=docker}"

# Every password value held in the per-service files, one per line.
values=
for f in "$dir"/*.env; do
    [ -f "$f" ] || continue
    for name in $(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$f"); do
        values+=$(. "$f"; printf '%s' "${!name}")$'\n'
    done
done

rc=0
for c in "$@"; do
    env=$("$DOCKER" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c") \
        || { echo "check-container-env: cannot inspect $c" >&2; exit 2; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        name=${line%%=*}
        value=${line#*=}
        if [[ $name =~ [Pp][Aa][Ss][Ss][Ww]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn] ]]; then
            echo "container $c: environment variable $name looks like a secret"
            rc=1
        elif [ -n "$value" ] && grep -qxF -- "$value" <<< "$values"; then
            echo "container $c: environment variable $name holds a stack password"
            rc=1
        fi
    done <<< "$env"
done
[ "$rc" -ne 0 ] || echo "no secrets in the environment of $# containers"
exit "$rc"
