"""Checks the Python interpreter and test libraries in the image."""
import sys
import unittest

import mock
import MySQLdb


class ToolchainTest(unittest.TestCase):

    def test_python_version(self):
        self.assertEqual(sys.version_info[:3], (2, 7, 3))

    def test_mysqldb_version(self):
        self.assertEqual(MySQLdb.__version__, '1.2.3')

    def test_mock_version(self):
        self.assertEqual(mock.__version__, '0.8.0')


if __name__ == '__main__':
    unittest.main()
