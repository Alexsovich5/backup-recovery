#!/usr/bin/env bats
# Key separation after every other suite has run: the director container
# (Director, Storage Daemon and backup-fd) holds no private key anywhere it
# can read, including volumes, restores and the offsite copy; server01
# holds its own keypair and the master certificate but not the master
# private key. The master key's use is shown by tests/drill/10-drill (drill-fd on
# dr-client decrypts), and 40-restore shows that an FD without keys
# cannot decrypt server01's data.

load helpers

# Any PEM private key block, whatever its type.
PRIVATE_RE='^-----BEGIN [A-Z ]*PRIVATE KEY-----'

@test "no private key file exists anywhere the director can read" {
  dirs=""
  for d in /etc /root /src /tmp /var /keys /keysafe /masterpub /restores \
           /drill-restores /offsite /clientdata /opt /home /usr/local; do
    [ -e "$d" ] && dirs="$dirs $d"
  done
  echo "scanned:$dirs"
  run bash -c "grep -rlE -- '$PRIVATE_RE' $dirs 2>/dev/null"
  echo "$output"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "the director has no key directory mounted" {
  for d in /keys /keysafe /masterpub /etc/bacula/keys /etc/bacula/keysafe; do
    if [ -e "$d" ]; then
      echo "$d exists"
      false
    fi
  done
}

@test "server01 holds its keypair and the master certificate, not the master key" {
  out=$(bcon "estimate job=server01-full fileset=KeyDirFileSet level=Full listing")
  echo "$out"
  grep -q '/etc/bacula/keys/server01.pem$' <<< "$out"
  grep -q '/etc/bacula/keys/master.cert$' <<< "$out"
  run grep -cE '/etc/bacula/keys/master\.(key|pem)$' <<< "$out"
  [ "$output" = "0" ]
}

@test "server01's backups do not contain its key directory" {
  run sql "SELECT COUNT(*) FROM File f JOIN Path p ON p.PathId = f.PathId JOIN Job j ON j.JobId = f.JobId WHERE j.Name LIKE 'server01-%' AND p.Path LIKE '/etc/bacula/keys%'"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}
