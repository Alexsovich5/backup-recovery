#!/usr/bin/env bats
# Package retrieval for the image stays authenticated: no Dockerfile or apt
# file in the repository bypasses signature checks or uses plain HTTP,
# docker/apt/fetch-debs.sh keeps its HTTPS-only download and its gpgv and
# SHA256 checks, and the wheezy stage installs only the verified set.

ROOT="$BATS_TEST_DIRNAME/../.."

BYPASS='--allow-unauthenticated|--force-yes|trusted=yes|AllowUnauthenticated|--no-check-gpg|allow-insecure|http://'

# scan FILE... prints every forbidden line as FILE:LINE:TEXT.
scan() {
  grep -nHiE -- "$BYPASS" "$@" || true
}

# Every Dockerfile and apt-related file tracked in the repository.
apt_files() {
  (cd "$ROOT" && find . -path ./.git -prune -o -path ./build -prune -o -type f \
    \( -name 'Dockerfile*' -o -name '*.dockerfile' -o -path './docker/apt/*' \
       -o -name '*.list' -o -name '*.sources' -o -path '*apt.conf*' \
       -o -name 'preferences' \) -print | sort)
}

setup() {
  WORK="$BATS_TMPDIR/apt-sources.$$"
  rm -rf "$WORK"
  mkdir -p "$WORK"
}

teardown() {
  rm -rf "$WORK"
}

@test "the scanner catches every form of the bypass" {
  cat > "$WORK/Dockerfile.bad" <<'EOF'
RUN echo 'deb http://snapshot.debian.org/archive/debian/20140131T000000Z wheezy main' > /etc/apt/sources.list
RUN echo 'APT::Get::AllowUnauthenticated "true";' > /etc/apt/apt.conf.d/10archive
RUN apt-get install -y --force-yes make
RUN apt-get install -y --allow-unauthenticated make
RUN echo 'deb [trusted=yes] https://example.invalid/debian wheezy main' > /etc/apt/sources.list
RUN apt-get -o Acquire::AllowInsecureRepositories=true --no-check-gpg update
EOF
  [ "$(scan "$WORK/Dockerfile.bad" | wc -l)" -eq 6 ]
}

@test "no Dockerfile or apt file holds an unauthenticated or plain-HTTP source" {
  files=$(apt_files)
  echo "$files"
  echo "$files" | grep -qx './Dockerfile'
  echo "$files" | grep -qx './docker/apt/fetch-debs.sh'
  bad=$(cd "$ROOT" && scan $files)
  echo "$bad"
  [ -z "$bad" ]
}

@test "every package source is an HTTPS snapshot.debian.org URL" {
  urls=$(grep -v '^[[:space:]]*#' "$ROOT/docker/apt/sources.conf" | awk 'NF { print $2 }')
  echo "$urls"
  [ -n "$urls" ]
  [ -z "$(echo "$urls" | grep -v '^https://snapshot\.debian\.org/')" ]
}

@test "fetch-debs.sh downloads over HTTPS only and checks signatures and SHA256" {
  f="$ROOT/docker/apt/fetch-debs.sh"
  grep -q -- "--proto '=https' --proto-redir '=https'" "$f"
  grep -q 'gpgv --status-fd' "$f"
  grep -q 'debian-archive-keyring.gpg' "$f"
  grep -q 'debian-archive-removed-keys.gpg' "$f"
  grep -q 'VALIDSIG' "$f"
  [ "$(grep -c '^ *check_sha256 "' "$f")" -ge 2 ]
}

@test "the lock pins every package named in the SPEC pin list" {
  lock="$ROOT/docker/apt/packages.lock"
  for pv in bacula-common=5.2.6+dfsg-9 bacula-director-mysql=5.2.6+dfsg-9 \
            bacula-sd-mysql=5.2.6+dfsg-9 bacula-fd=5.2.6+dfsg-9 \
            bacula-console=5.2.6+dfsg-9 mysql-server=5.5.35+dfsg-0+wheezy1 \
            libmysqlclient18=5.5.35+dfsg-0+wheezy1 openssl=1.0.1e-2+deb7u3 \
            libssl1.0.0=1.0.1e-2+deb7u3 python2.7=2.7.3-6 python-mysqldb=1.2.3-2 \
            python-mock=0.8.0-3 python-nose=1.1.2-3 rsync=3.0.9-4 make=3.81-8.2; do
    awk -v p="${pv%%=*}" -v v="${pv#*=}" '$2 == p && $3 == v { f = 1 } END { exit !f }' "$lock" || {
      echo "not pinned: $pv"
      return 1
    }
  done
}

@test "the wheezy stage installs the verified debs with dpkg, not apt-get" {
  wheezy=$(awk '/^FROM debian:wheezy/ { s = 1 } s' "$ROOT/Dockerfile")
  [ -n "$wheezy" ]
  run grep -c 'apt-get' <<< "$wheezy"
  [ "$output" = "0" ]
  echo "$wheezy" | grep -q 'install-debs.sh /tmp/debs'
  grep -q 'dpkg -i' "$ROOT/docker/apt/install-debs.sh"
}

@test "the built image has no apt sources and no bypass settings" {
  [ -d /etc/apt ]
  srcs=$(cat /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true)
  echo "$srcs"
  [ -z "$srcs" ]
  run bash -c "apt-config dump | grep -iE 'AllowUnauthenticated \"(true|1)\"|AllowInsecure'"
  echo "$output"
  [ "$status" -eq 1 ]
}
