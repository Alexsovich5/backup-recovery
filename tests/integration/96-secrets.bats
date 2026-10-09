#!/usr/bin/env bats
# Secrets are split per service: the director container holds its own
# secret file only, and neither the recovery daemon's password nor the
# drill account's password reaches it (or its rendered configs).

load helpers

@test "the director has exactly one secret file, readable by root only" {
  [ "$(ls /run/secrets)" = "director" ]
  [ "$(stat -c %a /run/secrets/director | cut -c2-3)" = "00" ]
}

@test "the director's secret file holds the Bacula, catalog and offsite passwords only" {
  names=$(sed -n 's/^\([A-Z_]*\)=.*/\1/p' /run/secrets/director | sort | tr '\n' ' ')
  [ "$names" = "DB_PASSWORD DIR_PASSWORD FD_PASSWORD OFFSITE_PASSWORD SD_PASSWORD " ]
}

@test "the director does not know the recovery daemon or the drill account" {
  [ -z "$DRFD_PASSWORD" ]
  [ -z "$DRILL_DB_PASSWORD" ]
  run grep -rlE 'drill-fd|drill-dir|DRFD' /etc/bacula
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "the director's catalog account has no rights on the scratch catalog" {
  run sql "SHOW GRANTS FOR CURRENT_USER()"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c bacula_drill)" -eq 0 ]
}

# Run again while dr-client is up (scripts/stack-test.sh), when the name
# resolves for the services that share its network.
@test "the director cannot reach drill-fd on dr-client" {
  if (exec 3<> "/dev/tcp/dr-client/9202") 2>/dev/null; then
    echo "dr-client answered"
    false
  fi
}
