FROM debian:wheezy

ENV DEBIAN_FRONTEND=noninteractive

# Use only the 2014-01-31 snapshot of wheezy and wheezy/updates.
RUN printf '%s\n' \
      'deb http://snapshot.debian.org/archive/debian/20140131T000000Z wheezy main' \
      'deb http://snapshot.debian.org/archive/debian-security/20140131T000000Z wheezy/updates main' \
      > /etc/apt/sources.list \
 && printf '%s\n' 'Package: *' 'Pin: origin snapshot.debian.org' 'Pin-Priority: 1001' \
      > /etc/apt/preferences \
 && printf '%s\n' 'Acquire::Check-Valid-Until "false";' 'Acquire::Retries "3";' \
      > /etc/apt/apt.conf.d/10snapshot \
 && printf '%s\n' \
      'bacula-director-mysql bacula-director-mysql/dbconfig-install boolean false' \
      'bacula-director-mysql bacula-director-mysql/dbconfig-upgrade boolean false' \
      | debconf-set-selections

# The archive signing keys have expired, hence --force-yes.
RUN for i in 1 2 3; do apt-get update && break; sleep 5; done \
 && apt-get install -y --force-yes --no-install-recommends \
      bacula-common=5.2.6+dfsg-9 \
      bacula-common-mysql=5.2.6+dfsg-9 \
      bacula-director-common=5.2.6+dfsg-9 \
      bacula-director-mysql=5.2.6+dfsg-9 \
      bacula-sd=5.2.6+dfsg-9 \
      bacula-sd-mysql=5.2.6+dfsg-9 \
      bacula-fd=5.2.6+dfsg-9 \
      bacula-console=5.2.6+dfsg-9 \
      mysql-server=5.5.35+dfsg-0+wheezy1 \
      mysql-server-5.5=5.5.35+dfsg-0+wheezy1 \
      mysql-server-core-5.5=5.5.35+dfsg-0+wheezy1 \
      mysql-client-5.5=5.5.35+dfsg-0+wheezy1 \
      mysql-common=5.5.35+dfsg-0+wheezy1 \
      libmysqlclient18=5.5.35+dfsg-0+wheezy1 \
      openssl=1.0.1e-2+deb7u3 \
      libssl1.0.0=1.0.1e-2+deb7u3 \
      python2.7=2.7.3-6 \
      python2.7-minimal=2.7.3-6 \
      libpython2.7=2.7.3-6 \
      python-mysqldb=1.2.3-2 \
      python-mock=0.8.0-3 \
      python-nose=1.1.2-3 \
      rsync=3.0.9-4 \
      make=3.81-8.2 \
 && rm -rf /var/lib/apt/lists/*

# Bats 0.3.1 (tag v0.3.1, commit 2e24778).
ADD https://github.com/sstephenson/bats/archive/v0.3.1.tar.gz /tmp/bats.tar.gz
RUN echo '8c5b25b8b4cc3f04322d2dbc474d06b04c0d2f658782324eea6fc851755bf509  /tmp/bats.tar.gz' \
      | sha256sum -c - \
 && tar -xzf /tmp/bats.tar.gz -C /tmp \
 && /tmp/bats-0.3.1/install.sh /usr/local \
 && rm -rf /tmp/bats.tar.gz /tmp/bats-0.3.1

WORKDIR /src
