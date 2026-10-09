# Shared helpers for the integration suites. Load with "load helpers".
#
# Access rules: every suite runs inside the director container and reaches
# the other containers only through their network daemons and the shared
# named volumes:
#   - Director, Storage Daemon and File Daemons through bconsole (bcon),
#   - the MySQL catalog on host "catalog" through the mysql client (sql),
#   - client data under /clientdata/server01 (server01 /srv/data),
#   - restored files under /restores (same path on server01),
#   - the SMTP sink log at /var/log/smtp-sink/smtp.log (read-only),
#   - the offsite rsync daemon (offsite_rsync) and its volume at /offsite
#     (read-only),
# The DR drill itself runs in the drill service (tests/drill), not here:
# the director has neither the recovery daemon's password nor any route to
# dr-client.
# No test uses a Docker CLI, a Docker socket or SSH, and no test stops a
# container; forced failures go through dedicated Bacula jobs.

SRC=/src
BCONSOLE_CONF=/etc/bacula/bconsole.conf
WAIT_INTERVAL=2
WAIT_TIMEOUT=300
LOG_FILE=

set -a
. "$SRC/config/bacula.env"
. /run/secrets/director
set +a

. "$SRC/scripts/lib/common.sh"

# bcon "<commands>"
# Sends the commands (newline separated) to the Director and prints the
# output.
bcon() {
  bconsole_cmd "$1"
}

# run_and_wait JOB [ARGS...]
# Queues "run job=JOB ARGS... yes", waits for the job and prints
# "<jobid> <status>". Returns 0 only when the job ended in T.
run_and_wait() {
  local job=$1 out jobid st
  shift
  out=$(bcon "run job=$job $* yes")
  jobid=$(printf '%s\n' "$out" | parse_jobid) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  st=$(wait_job "$jobid") || st=timeout
  echo "$jobid $st"
  [ "$st" = "T" ]
}

# last_jobid NAME
# Prints the highest JobId recorded in the catalog for job NAME.
last_jobid() {
  sql "SELECT MAX(JobId) FROM Job WHERE Name='$1'"
}

# wait_for_file_match FILE REGEX SECS
# Returns 0 as soon as FILE contains a line matching REGEX (grep -E),
# 1 when SECS seconds pass without a match.
wait_for_file_match() {
  local file=$1 regex=$2 secs=$3 i
  for ((i = 0; i <= secs; i++)); do
    if [ -f "$file" ] && grep -qE "$regex" "$file"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# sql QUERY
# Runs QUERY against the bacula catalog and prints tab-separated rows
# without a header. The credentials come from the option file the
# director entrypoint writes, not from the command line.
sql() {
  mysql --defaults-extra-file=/etc/bacula/catalog.cnf -h "$DB_HOST" -N -B bacula -e "$1"
}

# offsite_rsync ARGS...
# rsync with the offsite login (user bacula, password file written by the
# director entrypoint).
offsite_rsync() {
  rsync --password-file=/etc/bacula/offsite.passwd "$@"
}
