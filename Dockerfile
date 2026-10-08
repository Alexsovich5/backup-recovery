# Stage 1: download and verify every package on a current Debian, over
# HTTPS from snapshot.debian.org: Release signatures with gpgv, the
# Packages index and each .deb by SHA256 (see docker/apt/fetch-debs.sh).
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587 AS fetch

RUN for i in 1 2 3; do apt-get update && break; sleep 10; done \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gpgv debian-archive-keyring \
 && rm -rf /var/lib/apt/lists/*

COPY docker/apt/ /apt/
RUN bash /apt/fetch-debs.sh /apt/sources.conf /apt/packages.lock /debs

# Bats 0.3.1 (tag v0.3.1, commit 2e24778), checked by SHA256.
RUN for i in 1 2 3; do \
      curl -fsSL --proto '=https' --proto-redir '=https' -o /tmp/bats.tar.gz \
        https://github.com/sstephenson/bats/archive/v0.3.1.tar.gz && break; sleep 5; done \
 && echo '8c5b25b8b4cc3f04322d2dbc474d06b04c0d2f658782324eea6fc851755bf509  /tmp/bats.tar.gz' \
      | sha256sum -c - \
 && mkdir /bats && tar -xzf /tmp/bats.tar.gz -C /bats --strip-components=1

# Stage 2: the wheezy image. Packages come only from the verified set
# above, installed with dpkg; the image has no apt sources at all.
FROM debian:wheezy@sha256:2259b099d947443e44bbd1c94967c785361af8fd22df48a08a3942e2d5630849

ENV DEBIAN_FRONTEND=noninteractive

RUN rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
 && printf '%s\n' \
      'bacula-director-mysql bacula-director-mysql/dbconfig-install boolean false' \
      'bacula-director-mysql bacula-director-mysql/dbconfig-upgrade boolean false' \
      | debconf-set-selections

RUN --mount=type=bind,from=fetch,source=/debs,target=/tmp/debs \
    --mount=type=bind,source=docker/apt,target=/tmp/apt \
    bash /tmp/apt/install-debs.sh /tmp/debs \
 && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /bats /tmp/bats-0.3.1
RUN /tmp/bats-0.3.1/install.sh /usr/local && rm -rf /tmp/bats-0.3.1

WORKDIR /src
