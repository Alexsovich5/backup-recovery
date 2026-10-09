#!/bin/bash
#
# stack-test.sh: the integration run behind "make integration".
#
#   1. creates the master keypair (dr-client init) and brings the stack up
#   2. waits up to 120 s for the Director, then runs tests/integration in
#      the director container
#   3. starts dr-client for the length of the drill, runs tests/drill in
#      the drill service, re-checks the director's isolation while
#      dr-client is up, and checks that no container carries a password
#      in its environment
#   4. always stops dr-client and tears the stack down with its volumes
#
# Environment: COMPOSE (default "docker compose -p backup-recovery").
# Exit status: that of the first failing step.

: "${COMPOSE:=docker compose -p backup-recovery}"
cd "$(dirname "$0")/.." || exit 1

status=0

teardown() {
    $COMPOSE --profile drill down -v --remove-orphans
}
trap teardown EXIT

step() {
    [ "$status" -eq 0 ] || return 0
    "$@" || status=$?
}

dir_answers() {
    $COMPOSE exec -T director bash -c 'for i in $(seq 60); do
        echo "status dir" | bconsole -c /etc/bacula/bconsole.conf 2>/dev/null \
          | grep -q "^Daemon started " && exit 0; sleep 2; done; exit 1'
}

step $COMPOSE --profile drill run --rm -T dr-client init
step $COMPOSE up -d
[ "$status" -ne 0 ] || echo "waiting for the Director (up to 120 s)"
step dir_answers
if [ "$status" -ne 0 ]; then
    echo "stack did not come up or the Director did not answer within 120 s"
    $COMPOSE --profile drill logs --tail=50
    exit "$status"
fi

step $COMPOSE exec -T director bats /src/tests/integration
step $COMPOSE --profile drill up -d dr-client
step $COMPOSE --profile drill run --rm -T drill bats /src/tests/drill
step $COMPOSE exec -T director bats /src/tests/integration/96-secrets.bats
# shellcheck disable=SC2046
step scripts/check-container-env.sh secrets $($COMPOSE --profile drill ps -aq)
$COMPOSE --profile drill rm -sf dr-client
exit "$status"
