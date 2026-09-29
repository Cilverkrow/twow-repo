"""tools/scan_summons.py on synthetic C++ sources."""

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

from synth import ROOT

sys.path.insert(0, str(ROOT / "tools"))
import scan_summons  # noqa: E402

from dbcheck.expected import load_expected  # noqa: E402


def write(root: Path, rel: str, text: str):
    p = root / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text, encoding="utf-8")


class Scan(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        write(self.root, "src/scripts/a/boss_a.h", "enum { NPC_ALPHA = 11111, NPC_UNUSED = 22222 };\n")
        write(self.root, "src/scripts/a/boss_a.cpp",
              "void f() {\n  me->SummonCreature(NPC_ALPHA, 1, 2, 3, 0, TEMPSUMMON_DEAD_DESPAWN, 0);\n}\n")
        write(self.root, "src/scripts/b/boss_b.cpp",
              "constexpr std::uint32_t BOSS_BETA = 33333;\nvoid g() { GetMap()->SummonCreature(BOSS_BETA, 1, 2, 3, 0); }\n")
        write(self.root, "src/game/c.cpp", "#define NPC_GAMMA 44444\nvoid h() { pCaster->DoSpawnCreature(NPC_GAMMA, 0, 0, 0, 0, TEMPSUMMON_TIMED_DESPAWN, 1); }\n")
        write(self.root, "src/scripts/d/d.cpp", "void i() { m_creature->SummonCreature(55555, 1, 2, 3, 0); }\nvoid j(uint32 e) { SummonCreature(e, 1, 2, 3, 0); }\n")
        write(self.root, "src/scripts/d/comment.cpp", "// me->SummonCreature(66666, 1, 2, 3, 0);\n")
        self.cands = {11111: "Alpha", 33333: "Beta", 44444: "Gamma", 55555: "Delta", 66666: "Commented", 77777: "Never"}

    def tearDown(self):
        self.tmp.cleanup()

    def test_numbers_enums_constexpr_and_define_are_resolved(self):
        rows = {e: where for e, _, where in scan_summons.scan(self.root, self.cands)}
        self.assertEqual(sorted(rows), [11111, 33333, 44444, 55555])
        self.assertEqual(rows[11111], "src/scripts/a/boss_a.cpp:2 (NPC_ALPHA)")
        self.assertEqual(rows[33333], "src/scripts/b/boss_b.cpp:2 (BOSS_BETA)")  # constexpr with a type in front
        self.assertEqual(rows[44444], "src/game/c.cpp:2 (NPC_GAMMA)")  # #define
        self.assertEqual(rows[55555], "src/scripts/d/d.cpp:1 (55555)")  # a plain number

    def test_comments_variables_and_non_candidates_are_ignored(self):
        found = {e for e, _, _ in scan_summons.scan(self.root, self.cands)}
        self.assertNotIn(66666, found)  # only in a comment
        self.assertNotIn(77777, found)  # never summoned
        self.assertNotIn(22222, found)  # a constant nobody summons

    def test_output_is_a_valid_expected_list(self):
        rows = scan_summons.scan(self.root, self.cands)
        text = scan_summons.render(rows, "abc1234", "2026-09-29")
        p = self.root / "list.toml"
        p.write_text(text, encoding="utf-8")
        exp = load_expected(p)
        self.assertEqual(sorted(s.entry for s in exp.summoned), [11111, 33333, 44444, 55555])
        self.assertIn("boss_a.cpp:2", [s.note for s in exp.summoned if s.entry == 11111][0])
        self.assertEqual({s.via for s in exp.summoned}, {"cpp"})

    def test_command_line(self):
        cand = self.root / "ids.txt"
        cand.write_text("# id name\n11111 Alpha\n33333 Beta\n", encoding="utf-8")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = scan_summons.main(["--core-src", str(self.root), "--candidates", str(cand), "--core-commit", "abc1234"])
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue().count("[[summoned_boss]]"), 2)
        self.assertIn("2 of the candidates proven", err.getvalue())


if __name__ == "__main__":
    unittest.main()
