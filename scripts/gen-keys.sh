#!/bin/bash
#
# gen-keys.sh <outdir> <client-name>
#
# Generates the Bacula File Daemon PKI material with OpenSSL:
#   <client>.key   RSA private key of the client
#   <client>.cert  self-signed certificate for that key
#   <client>.pem   key + certificate, used as "PKI Keypair" on the client
#   master.key     private master recovery key (keep it off the client)
#   master.cert    master recovery certificate, used as "PKI Master Key"
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
    echo "usage: $0 <outdir> <client-name>" >&2
    exit 2
}

[ $# -eq 2 ] || usage
outdir=$1
client=$2
[[ $client =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage

files="$client.key $client.cert $client.pem master.key master.cert"
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

if ! genkey "$client" "$client-fd" || ! genkey master "bacula-master-recovery"; then
    echo "gen-keys: openssl failed" >&2
    exit 1
fi
cat "$tmp/$client.key" "$tmp/$client.cert" > "$tmp/$client.pem" || exit 1
chmod 0644 "$tmp/$client.cert" "$tmp/master.cert"

for f in $files; do
    mv "$tmp/$f" "$outdir/$f" || exit 1
done
echo "gen-keys: wrote $files to $outdir"
