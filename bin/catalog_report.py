#!/usr/bin/env python
"""Report failed Bacula jobs and stale clients from the MySQL catalog.

Reads the stock Bacula 5.2 Job and Client tables (read-only) and exits
with a Nagios-style code:

    0 OK        every client has a successful backup inside max-age and
                no backup/verify job failed inside the window
    1 WARNING   a client's last successful backup is older than max-age
                (or it has none)
    2 CRITICAL  a backup or verify job ended in error (E) or fatal (f)
                inside the window
    3 UNKNOWN   the catalog could not be queried

Only Type 'B' (backup) and 'V' (verify) jobs are counted; restores and
other job types are ignored.
"""
import argparse
import datetime
import sys

import MySQLdb

OK, WARNING, CRITICAL, UNKNOWN = 0, 1, 2, 3
STATE_NAMES = {OK: 'OK', WARNING: 'WARNING', CRITICAL: 'CRITICAL',
               UNKNOWN: 'UNKNOWN'}

COUNTED_TYPES = ('B', 'V')
FAILED_STATUSES = ('E', 'f')

# One row per client, plus one per counted job started since the cutoff.
# The cutoff is passed as a query parameter.
QUERY = """
SELECT c.Name, j.JobId, j.Name, j.Type, j.JobStatus,
       j.SchedTime, j.EndTime
  FROM Client c
  LEFT JOIN Job j
    ON j.ClientId = c.ClientId
   AND j.Type IN ('B', 'V')
   AND j.SchedTime >= %s
 ORDER BY c.Name, j.JobId
"""


def classify(rows, now, max_age, since):
    """Classify catalog rows.

    rows: sequence of (client, jobid, job name, type, status, start, end);
          a client without jobs has None in every job column.
    now: datetime of the check; max_age, since: timedeltas.

    Returns a dict with state, code, clients, failed and stale.
    failed: list of (jobid, job name, client, type, status, start).
    stale: list of (client, last successful backup end time or None).
    """
    clients = set()
    last_good = {}
    failed = []
    window_start = now - since
    for client, jobid, name, jtype, status, start, end in rows:
        clients.add(client)
        last_good.setdefault(client, None)
        if jobid is None or jtype not in COUNTED_TYPES:
            continue
        if status in FAILED_STATUSES and start is not None \
                and start >= window_start:
            failed.append((jobid, name, client, jtype, status, start))
        if jtype == 'B' and status == 'T':
            when = end or start
            if when is not None and (last_good[client] is None
                                     or when > last_good[client]):
                last_good[client] = when

    stale = []
    for client in sorted(clients):
        when = last_good[client]
        if when is None or now - when > max_age:
            stale.append((client, when))

    if failed:
        code = CRITICAL
    elif stale:
        code = WARNING
    else:
        code = OK
    return {
        'state': STATE_NAMES[code],
        'code': code,
        'clients': sorted(clients),
        'failed': failed,
        'stale': stale,
        'max_age': max_age,
        'since': since,
    }


def _hours(delta):
    return int(delta.days * 24 + delta.seconds // 3600)


def _summary(result):
    parts = []
    if result['failed']:
        parts.append('%d failed job(s): %s' % (
            len(result['failed']),
            ', '.join('%s (JobId %s, %s)' % (f[1], f[0], f[4])
                      for f in result['failed'])))
    if result['stale']:
        parts.append('%d stale client(s): %s' % (
            len(result['stale']),
            ', '.join(s[0] for s in result['stale'])))
    if not parts:
        parts.append('%d client(s) backed up within %dh, no failed jobs '
                     'in the last %dh' % (len(result['clients']),
                                          _hours(result['max_age']),
                                          _hours(result['since'])))
    return '; '.join(parts)


def render(result, fmt):
    """Render a classify() result as 'text' (multi-line) or 'nagios'."""
    head = 'BACULA %s - %s' % (result['state'], _summary(result))
    if fmt == 'nagios':
        perf = 'failed=%d stale=%d clients=%d' % (
            len(result['failed']), len(result['stale']),
            len(result['clients']))
        return '%s|%s' % (head, perf)

    lines = [head, '', 'Failed backup/verify jobs in the last %dh:'
             % _hours(result['since'])]
    if result['failed']:
        for jobid, name, client, jtype, status, start in result['failed']:
            lines.append('  JobId %s %s client=%s type=%s status=%s '
                         'started=%s' % (jobid, name, client, jtype, status,
                                         start))
    else:
        lines.append('  none')
    lines.append('Clients without a successful backup in the last %dh:'
                 % _hours(result['max_age']))
    if result['stale']:
        for client, when in result['stale']:
            if when is None:
                lines.append('  %s: no successful backup' % client)
            else:
                lines.append('  %s: last successful backup %s'
                             % (client, when))
    else:
        lines.append('  none')
    return '\n'.join(lines)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description='Report failed Bacula jobs and stale clients.')
    parser.add_argument('--host', default='localhost')
    parser.add_argument('--db', default='bacula')
    parser.add_argument('--user', default='bacula')
    parser.add_argument('--password-file', default=None,
                        help='file whose first line is the DB password')
    parser.add_argument('--max-age-hours', type=int, default=26)
    parser.add_argument('--since-hours', type=int, default=24)
    parser.add_argument('--format', choices=('text', 'nagios'),
                        default='text')
    return parser.parse_args(argv)


def fetch_rows(args, cutoff):
    password = ''
    if args.password_file:
        with open(args.password_file) as fh:
            password = fh.readline().rstrip('\n')
    conn = MySQLdb.connect(host=args.host, user=args.user, passwd=password,
                           db=args.db)
    try:
        cursor = conn.cursor()
        cursor.execute(QUERY, (cutoff,))
        return list(cursor.fetchall())
    finally:
        conn.close()


def main(argv=None, now=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if now is None:
        now = datetime.datetime.now()
    max_age = datetime.timedelta(hours=args.max_age_hours)
    since = datetime.timedelta(hours=args.since_hours)
    cutoff = now - max(max_age, since)
    try:
        rows = fetch_rows(args, cutoff)
    except (MySQLdb.Error, IOError) as exc:
        msg = 'BACULA UNKNOWN - cannot query catalog on %s: %s' % (
            args.host, exc)
        print(msg)
        return UNKNOWN
    result = classify(rows, now, max_age, since)
    print(render(result, args.format))
    return result['code']


if __name__ == '__main__':
    sys.exit(main())
