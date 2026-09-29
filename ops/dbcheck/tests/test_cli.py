"""CLI, report determinism and the committed configuration."""

import contextlib
import io
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from synth import ROOT, world

from dbcheck import report
from dbcheck.cli import main
from dbcheck.errors import ConfigError
from dbcheck.expected import load_all, load_expected


def run_cli(*args):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = main(list(args))
    return code, out.getvalue(), err.getvalue()


class Config(unittest.TestCase):
    def test_committed_configuration_is_valid(self):
        code, out, _ = run_cli("check")
        self.assertEqual(code, 0)
        self.assertIn("ok:", out)

    def test_every_expected_list_names_source_and_date(self):
        for e in load_all([ROOT / "expected"]):
            self.assertTrue(e.source and e.source_date, e.id)

    def test_expected_lists_hold_no_prose(self):
        for p in (ROOT / "expected").glob("*.toml"):
            for line in p.read_text(encoding="utf-8").splitlines():
                self.assertLess(len(line), 160, f"{p.name}: long line (quote from a source?)")

    def test_no_client_or_database_files_in_the_tree(self):
        for p in ROOT.rglob("*"):
            self.assertNotIn(p.suffix.lower(), {".dbc", ".mpq", ".sql", ".db", ".sqlite"}, str(p))

    def test_bad_expected_file_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "x.toml"
            p.write_text('[instance]\nid = "x"\nname = "x"\n[[boss]]\nentry = 1\n', encoding="utf-8")
            with self.assertRaises(ConfigError):  # no source / source_date
                load_expected(p)
            p.write_text('[instance]\nid="x"\nname="x"\nsource="s"\nsource_date="d"\n[[boss]]\nentry = "1; DROP"\n', encoding="utf-8")
            with self.assertRaises(ConfigError):
                load_expected(p)


class Cli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "world.db"
        dst = sqlite3.connect(self.db)
        world().backup(dst)
        dst.close()
        self.exp = Path(self.tmp.name) / "exp"
        self.exp.mkdir()
        (self.exp / "s.toml").write_text(
            '[instance]\nid = "s"\nname = "S"\nsource = "synthetic"\nsource_date = "2026-09-29"\n'
            '[[boss]]\nentry = 100\nname = "Boss Alpha"\nloot = ["Sword of Tests"]\n',
            encoding="utf-8",
        )

    def tearDown(self):
        self.tmp.cleanup()

    def test_run_reports_findings_with_exit_code_1(self):
        code, out, _ = run_cli("run", "--sqlite", str(self.db), "--expected", str(self.exp))
        self.assertEqual(code, 1)
        self.assertIn("quest_no_giver", out)
        self.assertIn("report sha256:", out)

    def test_clean_run_exits_0(self):
        code, out, _ = run_cli("run", "--sqlite", str(self.db), "--expected", str(self.exp), "--only", "boss_loot_missing,boss_unknown")
        self.assertEqual(code, 0)

    def test_report_is_deterministic_and_hashes_match_the_files(self):
        outs = []
        for i in (1, 2):
            o = Path(self.tmp.name) / f"out{i}"
            run_cli("run", "--sqlite", str(self.db), "--expected", str(self.exp), "--out", str(o))
            outs.append(o)
        a, b = (o.joinpath("report.md").read_bytes() for o in outs)
        self.assertEqual(a, b)
        sums = outs[0].joinpath("SHA256SUMS").read_text(encoding="utf-8").splitlines()
        self.assertEqual(sums[0].split()[0], report.sha256_of(a.decode("utf-8")))
        data = json.loads(outs[0].joinpath("report.json").read_text(encoding="utf-8"))
        self.assertGreater(data["counts"]["error"], 0)
        self.assertEqual(len(data["schema_fingerprint"]), 64)

    def test_max_rows_truncates_the_markdown_only(self):
        o = Path(self.tmp.name) / "o"
        run_cli("run", "--sqlite", str(self.db), "--expected", str(self.exp), "--out", str(o), "--max-rows", "1", "--only", "quest_chain_broken")
        self.assertIn("more rows", o.joinpath("report.md").read_text(encoding="utf-8"))
        data = json.loads(o.joinpath("report.json").read_text(encoding="utf-8"))
        self.assertEqual(len(data["findings"][0]["rows"]), 3)

    def test_errors_exit_2_with_a_message(self):
        code, _, err = run_cli("run", "--expected", str(self.exp))
        self.assertEqual(code, 2)
        self.assertIn("no database", err)
        code, _, err = run_cli("run", "--sqlite", str(self.db), "--expected", str(self.exp), "--only", "nope")
        self.assertEqual(code, 2)
        self.assertIn("unknown rule", err)

    def test_schema_drift_stops_the_run(self):
        con = sqlite3.connect(self.db)
        con.execute('ALTER TABLE "quest_template" DROP COLUMN "Title"')
        con.commit()
        con.close()
        code, _, err = run_cli("run", "--sqlite", str(self.db), "--expected", str(self.exp))
        self.assertEqual(code, 2)
        self.assertIn("does not match binding", err)

    def test_list_rules(self):
        code, out, _ = run_cli("list-rules")
        self.assertEqual(code, 0)
        self.assertIn("boss_no_spawn\tboss\terror", out)


if __name__ == "__main__":
    unittest.main()
