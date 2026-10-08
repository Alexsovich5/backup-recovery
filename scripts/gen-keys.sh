#!/bin/bash
#
# gen-keys.sh <outdir> <client-name>
# gen-keys.sh --client <outdir> <client-name>
# gen-keys.sh --master <outdir>
#
# Generates the Bacula File Daemon PKI material with OpenSSL:
#   <client>.key   RSA private key of the client
#   <client>.cert  self-signed certificate for that key
#   <client>.pem   key + certificate, used as "PKI Keypair" on the client
#   master.key     private master recovery key (keep it off the client)
#   master.cert    master recovery certificate, used as "PKI Master Key"
#   master.pem     master key + certificate, the "PKI Keypair" of the
#                  recovery File Daemon
#
# --client writes only the client files, --master only the master files,
# so the master private key can be created where it is kept and never on
# the client. Without an option both sets are written (used by make lint).
#
# Private key files are created mode 0600.
#
# Exit codes:
#   0  keys written
#   1  a target file already exists (nothing is changed) or openssl failed
#   2  usage error

set -u

BITS=2048
DAYS=3650

usage() {
    echo "usage: $0 [--client] <outdir> <client-name> | $0 --master <outdir>" >&2
    exit 2
}

mode=both
case "${1:-}" in
    --client) mode=client; shift ;;
    --master) mode=master; shift ;;
    -*) usage ;;
esac

client=
if [ "$mode" = master ]; then
    [ $# -eq 1 ] || usage
    outdir=$1
else
    [ $# -eq 2 ] || usage
    outdir=$1
    client=$2
    [[ $client =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
    # The client files must not overwrite or be mistaken for the master's.
    [ "$client" != master ] || usage
fi

files=
[ "$mode" = master ] || files="$client.key $client.cert $client.pem"
[ "$mode" = client ] || files="$files master.key master.cert master.pem"
files=${files# }
for f in $files; do
    if [ -e "$outdir/$f" ]; then
        echo "gen-keys: $outdir/$f already exists, not overwriting" >&2
        exit 1
    fi
done

umask 077
mkdir -p "$outdir" || exit 1

# Work in a temporary directory so a failure leaves no partial key set.
tmp=$(mktemp -d "$outdir/.gen-keys.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

# genkey <name> <common-name>: writes <name>.key and <name>.cert in $tmp.
genkey() {
    openssl genrsa -out "$tmp/$1.key" "$BITS" 2> /dev/null &&
    openssl req -new -x509 -days "$DAYS" -sha256 -key "$tmp/$1.key" \
        -subj "/CN=$2" -out "$tmp/$1.cert"
}

# keyset <name> <common-name>: <name>.key, <name>.cert and <name>.pem.
keyset() {
    genkey "$1" "$2" &&
    cat "$tmp/$1.key" "$tmp/$1.cert" > "$tmp/$1.pem" &&
    chmod 0644 "$tmp/$1.cert"
}

if [ "$mode" != master ] && ! keyset "$client" "$client-fd"; then
    echo "gen-keys: openssl failed" >&2
    exit 1
fi
if [ "$mode" != client ] && ! keyset master "bacula-master-recovery"; then
    echo "gen-keys: openssl failed" >&2
    exit 1
fi

for f in $files; do
    mv "$tmp/$f" "$outdir/$f" || exit 1
done
echo "gen-keys: wrote $files to $outdir"
