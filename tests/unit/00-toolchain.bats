#!/usr/bin/env bats
# Checks that the image carries exactly the pinned toolchain.

@test "bash is 4.2" {
  run bash --version
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"version 4.2."* ]]
}

@test "bacula-dir is 5.2.6" {
  run /usr/sbin/bacula-dir -?
  [[ "$output" == *"5.2.6"* ]]
}

@test "mysqld is 5.5.35" {
  run /usr/sbin/mysqld --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"5.5.35"* ]]
}

@test "rsync is 3.0.9" {
  run rsync --version
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"version 3.0.9 "* ]]
}

@test "openssl is 1.0.1e" {
  run openssl version
  [ "$status" -eq 0 ]
  [[ "$output" == "OpenSSL 1.0.1e "* ]]
}

@test "every package in the pin list is installed at its pinned version" {
  expected="bacula-common 5.2.6+dfsg-9
bacula-common-mysql 5.2.6+dfsg-9
bacula-director-common 5.2.6+dfsg-9
bacula-director-mysql 5.2.6+dfsg-9
bacula-sd 5.2.6+dfsg-9
bacula-sd-mysql 5.2.6+dfsg-9
bacula-fd 5.2.6+dfsg-9
bacula-console 5.2.6+dfsg-9
mysql-server 5.5.35+dfsg-0+wheezy1
mysql-server-5.5 5.5.35+dfsg-0+wheezy1
mysql-server-core-5.5 5.5.35+dfsg-0+wheezy1
mysql-client-5.5 5.5.35+dfsg-0+wheezy1
mysql-common 5.5.35+dfsg-0+wheezy1
libmysqlclient18 5.5.35+dfsg-0+wheezy1
openssl 1.0.1e-2+deb7u3
libssl1.0.0 1.0.1e-2+deb7u3
python2.7 2.7.3-6
python2.7-minimal 2.7.3-6
libpython2.7 2.7.3-6
python-mysqldb 1.2.3-2
python-mock 0.8.0-3
python-nose 1.1.2-3
rsync 3.0.9-4
make 3.81-8.2"
  pkgs=$(echo "$expected" | cut -d' ' -f1)
  run dpkg-query -W -f '${Package} ${Version}\n' $pkgs
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | sort)" = "$(echo "$expected" | sort)" ]
}

@test "apt sources contain no archive.debian.org or deb.debian.org line" {
  run grep -E 'archive\.debian\.org|deb\.debian\.org' /etc/apt/sources.list
  [ "$status" -eq 1 ]
}
