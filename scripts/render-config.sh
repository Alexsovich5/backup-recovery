#!/bin/bash
#
# render-config.sh <template> <output>
#
# Replaces every @NAME@ placeholder (NAME = upper case letters, digits and
# underscores) in <template> with the value of the environment variable NAME
# and writes the result to <output>.
#
# Values are inserted literally in a single pass, so '/', '&' and '\' in a
# value are kept as they are and a value is never scanned for placeholders.
#
# Exit codes:
#   0  rendered
#   2  usage error or unreadable template
#   3  a referenced variable is unset, or an @...@ token is left afterwards
#      (no output file is written in either case)

set -u

usage() {
    echo "usage: $0 <template> <output>" >&2
    exit 2
}

[ $# -eq 2 ] || usage
template=$1
output=$2

if [ ! -f "$template" ] || [ ! -r "$template" ]; then
    echo "render-config: cannot read template '$template'" >&2
    exit 2
fi

# Read the whole template; the sentinel keeps trailing newlines.
content=$(cat "$template"; printf x)
content=${content%x}

rendered=""
missing=""
rest=$content
re='@([A-Z][A-Z0-9_]*)@'
while [[ $rest =~ $re ]]; do
    token=${BASH_REMATCH[0]}
    name=${BASH_REMATCH[1]}
    rendered+=${rest%%"$token"*}
    rest=${rest#*"$token"}
    if [ -z "${!name+set}" ]; then
        case " $missing " in
            *" $name "*) ;;
            *) missing="${missing:+$missing }$name" ;;
        esac
        rendered+=$token
    else
        rendered+=${!name}
    fi
done
rendered+=$rest

if [ -n "$missing" ]; then
    echo "render-config: $template: unset variable(s): $missing" >&2
    exit 3
fi

stray=$(printf '%s' "$rendered" | grep -oE '@[A-Za-z0-9_]+@' | sort -u | tr '\n' ' ')
if [ -n "$stray" ]; then
    echo "render-config: $template: placeholder(s) left after rendering: $stray" >&2
    exit 3
fi

outdir=$(dirname "$output")
tmp=$(mktemp "$outdir/.render.XXXXXX") || exit 2
if ! printf '%s' "$rendered" > "$tmp"; then
    rm -f "$tmp"
    exit 2
fi
chmod 0640 "$tmp"
mv -f "$tmp" "$output"
