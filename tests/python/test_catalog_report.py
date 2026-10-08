"""Unit tests for bin/catalog_report.py with a mocked MySQL catalog."""
import datetime
import os
import sys
import unittest
from StringIO import StringIO

import mock
import MySQLdb

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'bin')
sys.path.insert(0, os.path.normpath(BIN))
import catalog_report  # noqa: E402

NOW = datetime.datetime(2014, 1, 20, 12, 0, 0)
HOUR = datetime.timedelta(hours=1)
MAX_AGE = 26 * HOUR
SINCE = 24 * HOUR


def row(client, jobid=None, name=None, jtype=None, status=None,
        hours_ago=None):
    """One catalog row: (client, jobid, job, type, status, start, end)."""
    if jobid is None:
        return (client, None, None, None, None, None, None)
    start = NOW - datetime.timedelta(hours=hours_ago)
    end = start + datetime.timedelta(minutes=5)
    return (client, jobid, name, jtype, status, start, end)


class ClassifyTest(unittest.TestCase):

    def test_all_terminated_and_recent_is_ok(self):
        rows = [
            row('server01-fd', 1, 'server01-full', 'B', 'T', 3),
            row('server01-fd', 2, 'Verify-server01', 'V', 'T', 2),
            row('backup-fd', 3, 'BackupCatalog', 'B', 'T', 1),
        ]
        result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
        self.assertEqual(result['state'], 'OK')
        self.assertEqual(result['code'], 0)
        self.assertEqual(result['failed'], [])
        self.assertEqual(result['stale'], [])
        self.assertEqual(result['clients'], ['backup-fd', 'server01-fd'])

    def test_last_success_older_than_max_age_is_warning(self):
        rows = [
            row('server01-fd', 1, 'server01-full', 'B', 'T', 30),
            row('backup-fd', 3, 'BackupCatalog', 'B', 'T', 1),
        ]
        result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
        self.assertEqual(result['state'], 'WARNING')
        self.assertEqual(result['code'], 1)
        self.assertEqual([s[0] for s in result['stale']], ['server01-fd'])

    def test_failed_backup_in_window_is_critical(self):
        for status in ('f', 'E'):
            rows = [
                row('server01-fd', 1, 'server01-full', 'B', 'T', 3),
                row('server01-fd', 2, 'server01-fail', 'B', status, 1),
            ]
            result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
            self.assertEqual(result['state'], 'CRITICAL')
            self.assertEqual(result['code'], 2)
            self.assertEqual([f[1] for f in result['failed']],
                             ['server01-fail'])

    def test_failed_verify_in_window_is_critical(self):
        rows = [
            row('server01-fd', 1, 'server01-full', 'B', 'T', 3),
            row('server01-fd', 2, 'Verify-server01', 'V', 'f', 2),
        ]
        result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
        self.assertEqual(result['code'], 2)
        self.assertEqual([f[1] for f in result['failed']], ['Verify-server01'])

    def test_failed_job_outside_window_is_not_counted(self):
        rows = [
            row('server01-fd', 1, 'server01-fail', 'B', 'f', 25),
            row('server01-fd', 2, 'server01-full', 'B', 'T', 3),
        ]
        result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
        self.assertEqual(result['code'], 0)
        self.assertEqual(result['failed'], [])

    def test_failed_restore_is_ignored(self):
        rows = [
            row('server01-fd', 1, 'server01-full', 'B', 'T', 3),
            row('server01-fd', 2, 'RestoreFiles', 'R', 'f', 1),
        ]
        result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
        self.assertEqual(result['state'], 'OK')
        self.assertEqual(result['code'], 0)
        self.assertEqual(result['failed'], [])

    def test_successful_verify_does_not_count_as_backup(self):
        rows = [row('server01-fd', 2, 'Verify-server01', 'V', 'T', 1)]
        result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
        self.assertEqual(result['code'], 1)
        self.assertEqual([s[0] for s in result['stale']], ['server01-fd'])

    def test_client_with_no_jobs_is_stale(self):
        rows = [
            row('server01-fd', 1, 'server01-full', 'B', 'T', 3),
            row('backup-fd'),
        ]
        result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
        self.assertEqual(result['state'], 'WARNING')
        self.assertEqual(result['code'], 1)
        self.assertEqual(result['stale'], [('backup-fd', None)])

    def test_critical_wins_over_warning(self):
        rows = [
            row('server01-fd', 2, 'server01-fail', 'B', 'f', 1),
            row('backup-fd'),
        ]
        result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
        self.assertEqual(result['code'], 2)
        self.assertEqual(len(result['stale']), 2)


class RenderTest(unittest.TestCase):

    def test_nagios_ok_is_one_line_with_perfdata(self):
        rows = [row('server01-fd', 1, 'server01-full', 'B', 'T', 3)]
        result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
        out = catalog_report.render(result, 'nagios')
        self.assertEqual(len(out.splitlines()), 1)
        self.assertTrue(out.startswith('BACULA OK - '), out)
        self.assertTrue('|' in out, out)
        self.assertTrue('failed=0' in out.split('|')[1], out)

    def test_nagios_critical_names_the_job(self):
        rows = [row('server01-fd', 7, 'server01-fail', 'B', 'f', 1)]
        result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
        out = catalog_report.render(result, 'nagios')
        self.assertEqual(len(out.splitlines()), 1)
        self.assertTrue(out.startswith('BACULA CRITICAL - '), out)
        self.assertTrue('server01-fail' in out, out)

    def test_text_lists_failed_jobs_and_stale_clients(self):
        rows = [
            row('server01-fd', 7, 'server01-fail', 'B', 'f', 1),
            row('backup-fd'),
        ]
        result = catalog_report.classify(rows, NOW, MAX_AGE, SINCE)
        out = catalog_report.render(result, 'text')
        self.assertTrue(out.splitlines()[0].startswith('BACULA CRITICAL'), out)
        self.assertTrue('JobId 7 server01-fail' in out, out)
        self.assertTrue('backup-fd: no successful backup' in out, out)


def fake_connection(rows):
    conn = mock.Mock()
    cursor = mock.Mock()
    cursor.fetchall.return_value = rows
    conn.cursor.return_value = cursor
    return conn, cursor


class MainTest(unittest.TestCase):

    def run_main(self, argv, connect):
        out = StringIO()
        with mock.patch.object(catalog_report.MySQLdb, 'connect', connect):
            with mock.patch.object(sys, 'stdout', out):
                code = catalog_report.main(argv, now=NOW)
        return code, out.getvalue()

    def test_sql_uses_parameters_not_string_formatting(self):
        conn, cursor = fake_connection(
            [row('server01-fd', 1, 'server01-full', 'B', 'T', 3)])
        connect = mock.Mock(return_value=conn)
        code, out = self.run_main(['--host', 'catalog', '--user', 'bacula'],
                                  connect)
        self.assertEqual(code, 0, out)
        self.assertEqual(cursor.execute.call_count, 1)
        args = cursor.execute.call_args[0]
        sql, params = args[0], args[1]
        self.assertTrue('%s' in sql, sql)
        cutoff = NOW - MAX_AGE
        self.assertTrue(cutoff in params, params)
        self.assertFalse(str(cutoff) in sql, sql)
        self.assertFalse('2014-' in sql, sql)
        self.assertEqual(connect.call_args[1]['host'], 'catalog')
        self.assertEqual(connect.call_args[1]['db'], 'bacula')
        conn.close.assert_called_once_with()

    def test_password_is_read_from_file(self):
        conn, _ = fake_connection([])
        connect = mock.Mock(return_value=conn)
        pwfile = os.path.join(os.environ.get('TMPDIR', '/tmp'),
                              'catalog-report-test-pw')
        with open(pwfile, 'w') as fh:
            fh.write('s3cret\n')
        try:
            self.run_main(['--password-file', pwfile], connect)
        finally:
            os.remove(pwfile)
        self.assertEqual(connect.call_args[1]['passwd'], 's3cret')

    def test_connect_error_is_unknown(self):
        connect = mock.Mock(side_effect=MySQLdb.OperationalError(
            2003, "Can't connect to MySQL server on 'catalog' (111)"))
        code, out = self.run_main(['--format', 'nagios'], connect)
        self.assertEqual(code, 3)
        self.assertTrue(out.startswith('BACULA UNKNOWN - '), out)

    def test_nagios_format_from_command_line(self):
        conn, _ = fake_connection(
            [row('server01-fd', 1, 'server01-full', 'B', 'T', 3)])
        code, out = self.run_main(['--format', 'nagios'],
                                  mock.Mock(return_value=conn))
        self.assertEqual(code, 0)
        self.assertEqual(len(out.strip().splitlines()), 1)
        self.assertTrue(out.startswith('BACULA OK - '), out)


if __name__ == '__main__':
    unittest.main()
