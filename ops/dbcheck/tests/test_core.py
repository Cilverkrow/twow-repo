"""Templates, binding, runners and the read-only guard."""

import sys
import unittest

from synth import BINDING, ROOT, empty_db

from dbcheck.binding import check_schema
from dbcheck.errors import ConfigError, RunnerError, SchemaError
from dbcheck.runner import MysqlRunner, SqliteRunner, parse_tsv, unescape_tsv
from dbcheck.template import check_readonly, expand, sql_int_list, sql_string, sql_string_list


class Template(unittest.TestCase):
    def test_names_come_from_the_binding(self):
        sql = expand("SELECT {creature_template.loot_id} FROM {creature_template} WHERE {creature_template.rank} = {const.boss_rank}",
                     BINDING, {}, {})
        self.assertEqual(sql, "SELECT `loot_id` FROM `creature_template` WHERE `rank` = 3")

    def test_logical_names_can_map_to_other_physical_names(self):
        self.assertEqual(BINDING.table("creature_loot"), "`creature_loot_template`")
        self.assertEqual(BINDING.column("quest", "title"), "`Title`")

    def test_macros_nest_and_params_expand_inside_them(self):
        out = expand("A {%outer}", BINDING, {"outer": "B {%inner}", "inner": "C {@x}"}, {"x": "7"})
        self.assertEqual(out, "A B C 7")

    def test_unknown_names_fail_loudly(self):
        for sql in ("{nope}", "{quest.nope}", "{const.nope}", "{@nope}", "{%nope}"):
            with self.assertRaises(ConfigError, msg=sql):
                expand(sql, BINDING, {}, {})

    def test_a_macro_cycle_terminates_with_an_error(self):
        with self.assertRaises(ConfigError):
            expand("{%a}", BINDING, {"a": "{%a}"}, {})

    def test_strings_are_escaped_and_hostile_ones_refused(self):
        self.assertEqual(sql_string("O'Brien"), "'O''Brien'")
        self.assertEqual(sql_string_list(["A", "B'c"]), "'a','b''c'")
        for bad in ("a\\b", "a\nb"):
            with self.assertRaises(ConfigError):
                sql_string(bad)
        with self.assertRaises(ConfigError):
            sql_int_list(["1; DROP TABLE x"])
        self.assertEqual(sql_int_list([]), "-1")
        self.assertEqual(sql_string_list([]), "''")

    def test_readonly_guard(self):
        check_readonly("SELECT 1", "t")
        check_readonly("SELECT 'Call of the Wild; DELETE it' AS x", "t")  # inside a literal: not code
        for bad in ("DELETE FROM x", "SELECT 1; SELECT 2", "SELECT 1 INTO OUTFILE '/x'", "UPDATE x SET a = 1", "SELECT SLEEP(5)"):
            with self.assertRaises(ConfigError, msg=bad):
                check_readonly(bad, "t")


class Binding(unittest.TestCase):
    def test_schema_matches_and_fingerprint_is_stable(self):
        a = check_schema(BINDING, SqliteRunner.from_connection(empty_db()).schema())
        b = check_schema(BINDING, SqliteRunner.from_connection(empty_db()).schema())
        self.assertEqual(a, b)
        self.assertEqual(len(a), 64)

    def test_missing_column_and_table_are_reported_together(self):
        con = empty_db()
        con.execute('DROP TABLE "npc_vendor"')
        con.execute('ALTER TABLE "quest_template" DROP COLUMN "RewItemId4"')
        with self.assertRaises(SchemaError) as cm:
            check_schema(BINDING, SqliteRunner.from_connection(con).schema())
        self.assertIn("npc_vendor", str(cm.exception))

    def test_a_missing_column_alone_is_named(self):
        con = empty_db()
        con.execute('ALTER TABLE "quest_template" DROP COLUMN "RewItemId4"')
        with self.assertRaises(SchemaError) as cm:
            check_schema(BINDING, SqliteRunner.from_connection(con).schema())
        self.assertIn("quest_template.RewItemId4", str(cm.exception))


class Runners(unittest.TestCase):
    def test_tsv_parsing_handles_null_and_escapes(self):
        cols, rows = parse_tsv("a\tb\n1\tNULL\nx\\ty\tz\\\\w\n")
        self.assertEqual(cols, ["a", "b"])
        self.assertEqual(rows, [("1", None), ("x\ty", "z\\w")])
        self.assertEqual(unescape_tsv("NULL"), None)

    def test_ragged_output_is_an_error(self):
        with self.assertRaises(RunnerError):
            parse_tsv("a\tb\n1\n")

    def test_mysql_runner_talks_to_a_client_command(self):
        # A stand-in client: reads SQL on stdin, prints a fixed batch-format answer.
        script = "import sys; sys.stdin.read(); print('x\\ty'); print('1\\tNULL')"
        r = MysqlRunner(f'"{sys.executable}" -c "{script}"')
        self.assertEqual(r.query("SELECT 1"), (["x", "y"], [("1", None)]))

    def test_batch_flag_is_added_when_missing(self):
        self.assertIn("-B", MysqlRunner("mariadb -u x").argv)
        self.assertEqual(MysqlRunner("mariadb --batch").argv.count("-B"), 0)

    def test_client_failure_is_an_error_not_an_empty_result(self):
        r = MysqlRunner(f'"{sys.executable}" -c "import sys; sys.stderr.write(\'boom\'); sys.exit(3)"')
        with self.assertRaises(RunnerError) as cm:
            r.query("SELECT 1")
        self.assertIn("boom", str(cm.exception))

    def test_runners_refuse_writes(self):
        for r in (SqliteRunner.from_connection(empty_db()), MysqlRunner("true")):
            with self.assertRaises(ConfigError):
                r.query("DELETE FROM creature")

    def test_sqlite_file_is_opened_read_only(self):
        import sqlite3
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "w.db"
            c = sqlite3.connect(p)
            c.execute("CREATE TABLE t (a)")
            c.commit()
            c.close()
            r = SqliteRunner(str(p))
            with self.assertRaises(Exception):
                r.con.execute("INSERT INTO t VALUES (1)")


if __name__ == "__main__":
    unittest.main()
