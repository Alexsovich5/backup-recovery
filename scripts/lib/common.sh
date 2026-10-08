#!/bin/bash
#
# Shared helpers for scripts that drive the Bacula Director via bconsole.
# Source this file; it defines functions only.
#
# Environment:
#   BCONSOLE_CONF  bconsole config file (default /etc/bacula/bconsole.conf)
#   LOG_FILE       file log_message appends to (optional)
#   WAIT_INTERVAL  seconds between polls in wait_job (default 5)
#   WAIT_TIMEOUT   seconds before wait_job gives up (default 7200)
#
# Apart from die, the helpers return a status instead of exiting, and the
# parsers read bconsole output on stdin, so they can be tested on fixtures.

: "${BCONSOLE_CONF:=/etc/bacula/bconsole.conf}"
: "${WAIT_INTERVAL:=5}"
: "${WAIT_TIMEOUT:=7200}"

# Job statuses after which a job will not change any more (D: a verify
# job that found differences).
TERMINAL_JOB_STATUSES="T W E e f A D"

# log_message MSG
# Writes "YYYY-MM-DD HH:MM:SS - MSG" to stderr and appends it to $LOG_FILE.
log_message() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') - $1"
    echo "$line" >&2
    if [ -n "$LOG_FILE" ]; then
        echo "$line" >> "$LOG_FILE"
    fi
}

# die CODE MSG
# Logs "ERROR: MSG" and exits with CODE.
die() {
    local code=$1
    shift
    log_message "ERROR: $*"
    exit "$code"
}

# bconsole_cmd "<commands>"
# Sends the commands (newline separated) followed by quit to bconsole and
# prints its output. Returns bconsole's exit status.
bconsole_cmd() {
    printf '%s\nquit\n' "$1" | bconsole -c "$BCONSOLE_CONF"
}

# parse_jobid
# Reads bconsole output on stdin and prints N from "Job queued. JobId=N".
# Returns 1 when no job was queued.
parse_jobid() {
    local id
    id=$(sed -n 's/^Job queued\. JobId=\([0-9][0-9]*\).*$/\1/p' | head -n 1)
    [ -n "$id" ] || return 1
    echo "$id"
}

# parse_job_status JOBID
# Reads the table printed by "list jobid=N" on stdin and prints the
# JobStatus column of the row for JOBID. Returns 1 when there is no such row.
parse_job_status() {
    local st
    st=$(awk -F'|' -v id="$1" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        /^\|/ && !col {
            for (i = 2; i < NF; i++) {
                if (trim($i) == "JobId") idcol = i
                if (trim($i) == "JobStatus") col = i
            }
            next
        }
        /^\|/ && col && trim($idcol) == id { print trim($col); exit }
    ')
    [ -n "$st" ] || return 1
    echo "$st"
}

# job_status JOBID
# Prints the one-letter JobStatus of JOBID from the catalog.
job_status() {
    bconsole_cmd "list jobid=$1" | parse_job_status "$1"
}

# wait_job JOBID
# Polls job_status every $WAIT_INTERVAL seconds until the job reaches a
# terminal status, then prints that status. Returns 1 after $WAIT_TIMEOUT
# seconds without a terminal status.
wait_job() {
    local id=$1 waited=0 st
    while :; do
        st=$(job_status "$id")
        # Matched as a string, so a caller's IFS cannot change the result.
        case " $TERMINAL_JOB_STATUSES " in
            *" $st "*)
                if [ -n "$st" ]; then
                    echo "$st"
                    return 0
                fi
                ;;
        esac
        if [ "$waited" -ge "$WAIT_TIMEOUT" ]; then
            log_message "ERROR: JobId $id not finished after ${WAIT_TIMEOUT}s (status '${st}')"
            return 1
        fi
        sleep "$WAIT_INTERVAL"
        waited=$((waited + WAIT_INTERVAL))
    done
}

# director_up
# Returns 0 when the Director answers "status dir", 1 otherwise.
director_up() {
    bconsole_cmd "status dir" 2>/dev/null | grep -q '^Daemon started '
}

# bacula_name_ok NAME
# Returns 0 when NAME is safe to place in a bconsole command as a client or
# job name: letters, digits, '.', '_', ':' and '-', starting with a letter
# or digit. Anything else (quotes, blanks, newlines) could end the argument
# or start a second console command.
bacula_name_ok() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]
}

# bconsole_arg_ok VALUE
# Returns 0 when VALUE (a path or time) holds no double quote and no control
# character, so it stays one argument of one bconsole command.
bconsole_arg_ok() {
    case "$1" in
        *'"'* | *[[:cntrl:]]*) return 1 ;;
    esac
    return 0
}

# check_manifest FILE
# Returns 0 when FILE is a non-empty md5sum manifest ("<md5>  <path>") whose
# paths are all relative and stay below the directory the manifest is
# checked from: no leading '/', no '..' component, no backslash-escaped
# names. Otherwise prints the first offending line number to stderr and
# returns 1. Callers delete and compare files by these paths, so a path
# leaving the restore directory would touch live data.
check_manifest() {
    local line path n=0 re='^[0-9a-f]{32} [ *](.+)$'
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        if [[ ! $line =~ $re ]]; then
            echo "manifest line $n is not an md5sum line" >&2
            return 1
        fi
        path=${BASH_REMATCH[1]}
        case "/$path/" in
            //* | */../*)
                echo "manifest line $n leaves the checked directory" >&2
                return 1
                ;;
        esac
    done < "$1"
    if [ "$n" -eq 0 ]; then
        echo "manifest lists no files" >&2
        return 1
    fi
    return 0
}
