"""Technical guards against a run on the wrong database (OB-40 review of #438)."""

import contextlib
import io
import sys
import unittest

from synth import BINDING, empty_db

from dbcheck.cli import main
from dbcheck.errors import ConfigError
from dbcheck.runner import MysqlRunner, SqliteRunner


def stand_in(script: str) -> str:
    return f'"{sys.executable}" -c "{script}"'


def run_cli(*args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = main(list(args))
    return code, out.getvalue(), err.getvalue()


class Guards(unittest.TestCase):
    def test_a_real_database_needs_the_disposable_flag(self):
        code, _, err = run_cli("run", "--mysql-cmd", "mariadb -u x", "--expected", "expected")
        self.assertEqual(code, 2)
        self.assertIn("--disposable", err)

    def test_sqlite_fixtures_need_no_flag(self):
        self.assertEqual(SqliteRunner.from_connection(empty_db()).check_grants(), [])

    def test_every_query_carries_a_statement_time_limit(self):
        # The stand-in fails (exit 3) unless the SQL it reads starts with the MariaDB limit.
        script = "import sys; s = sys.stdin.read(); sys.exit(0 if s.startswith('SET SESSION max_statement_time=120;') else 3); "
        r = MysqlRunner(stand_in(script.replace('"', "'")))
        try:
            r.query("SELECT 1")
        except Exception as e:  # empty output is parsed as no rows; only a non-zero exit is a failure
            self.fail(str(e))

    def test_the_limit_can_be_turned_off(self):
        self.assertEqual(MysqlRunner("mariadb", statement_seconds=0).prefix, "")

    def test_a_user_that_can_write_is_refused(self):
        script = "import sys; sys.stdin.read(); print('privilege_type'); print('SELECT'); print('DELETE'); print('USAGE')"
        r = MysqlRunner(stand_in(script))
        self.assertEqual(r.check_grants(), ["DELETE"])

    def test_a_read_only_user_passes(self):
        script = "import sys; sys.stdin.read(); print('privilege_type'); print('SELECT'); print('SHOW VIEW'); print('USAGE')"
        self.assertEqual(MysqlRunner(stand_in(script)).check_grants(), [])

    def test_the_cli_stops_on_a_writable_user(self):
        script = "import sys; sys.stdin.read(); print('privilege_type'); print('INSERT')"
        code, _, err = run_cli("run", "--mysql-cmd", stand_in(script), "--disposable", "--expected", "expected")
        self.assertEqual(code, 2)
        self.assertIn("INSERT", err)
        self.assertIn("read-only", err)


class Lists(unittest.TestCase):
    def test_a_list_constant_becomes_a_pattern_table(self):
        sql = BINDING.list_table("quest_ignore_title_like")
        self.assertIn("SELECT '[CANCELLED]%' AS pattern UNION ALL", sql)

    def test_a_scalar_is_not_a_list(self):
        with self.assertRaises(ConfigError):
            BINDING.list_table("boss_rank")


if __name__ == "__main__":
    unittest.main()
