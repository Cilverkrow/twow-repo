"""Quest feasibility catalog (twow-repo#601 R08a): loading, rendering, lint and the database check on a synthetic world."""

import re
import tempfile
import unittest
from pathlib import Path

from synth import BINDING, MACROS, ROOT, empty_db, insert

from dbcheck import catalog
from dbcheck.errors import ConfigError
from dbcheck.runner import SqliteRunner

CAT_DIR = ROOT / "catalog"
FACTS = catalog.load_facts(CAT_DIR / "facts.toml")

HEAD = '[catalog]\nfrozen_baseline = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]\n'


def entry(e, lst="blocklist", basis="rule", rule="PVP_BG", klass="impossible", extra=""):
    r = f'rule = "{rule}"\n' if basis == "rule" else ""
    return (f'\n[[quest]]\nentry = {e}\nlist = "{lst}"\nbasis = "{basis}"\n{r}class = "{klass}"\ncategory = "C"\n'
            f'title = "Quest {e}"\nreason = "because"\nevidence = "test"\n{extra}')


def load_text(text):
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "c.toml"
        p.write_text(text, encoding="utf-8")
        return catalog.load_catalog(p, FACTS)


class CommittedCatalog(unittest.TestCase):
    def test_counts_and_freeze(self):
        cat = catalog.load_catalog(CAT_DIR / "quest-feasibility.toml", FACTS)
        self.assertEqual(len(cat.quests), 94)
        self.assertEqual(sum(q.basis == "rule" for q in cat.quests), 47)   # strict split, OB-00 2026-10-19
        self.assertEqual(len(cat.ids("blocklist")), 87)
        self.assertEqual(len(cat.ids("no_custom_starts")), 7)
        self.assertEqual(set(cat.ids()), set(cat.baseline))

    def test_committed_files_are_current(self):
        cat = catalog.load_catalog(CAT_DIR / "quest-feasibility.toml", FACTS)
        self.assertEqual(catalog.lint(cat, CAT_DIR / "quest-feasibility.tsv", CAT_DIR / "quest-feasibility.keys", None), [])

    def test_every_fact_is_one_readonly_select(self):
        cat = catalog.load_catalog(CAT_DIR / "quest-feasibility.toml", FACTS)
        for f in FACTS.values():
            catalog.fact_sql(f, BINDING, MACROS, cat.ids())
            catalog.fact_sql(f, BINDING, MACROS, None)

    def test_no_derived_table_uses_the_outer_quest(self):
        # MariaDB has no LATERAL (ERROR 1109 "Unknown table 'q'"), SQLite accepts it: guard what the synthetic world cannot.
        for f in FACTS.values():
            for m in re.finditer(r"\bFROM\s*\(", f.predicate):
                depth, i = 1, m.end()
                while depth:
                    depth += {"(": 1, ")": -1}.get(f.predicate[i], 0)
                    i += 1
                self.assertIsNone(re.search(r"\bq\.", f.predicate[m.end():i]), f.name)


class Loading(unittest.TestCase):
    def test_valid(self):
        cat = load_text(HEAD + entry(1) + entry(2, basis="override", klass="needs_group") + entry(3, lst="no_custom_starts", basis="override", klass="config"))
        self.assertEqual(cat.ids("blocklist"), [1, 2])

    def test_rejects(self):
        bad = [
            entry(1) + entry(1),                                   # twice
            entry(1, lst="other"),                                 # unknown list
            entry(1, basis="maybe"),                               # unknown basis
            entry(1, rule="NO_SUCH_RULE"),                         # unknown rule
            entry(1, basis="override", extra='rule = "PVP_BG"\n'),  # override with a rule
            entry(1, klass="hard"),                                # unknown class
            entry(11),                                             # outside the frozen baseline, no approval
            entry(11, extra='approved = "maybe later"\n'),         # approval without the OB-00 form
            entry(1).replace('reason = "because"', 'reason = ""'),  # no reason
            entry(1).replace('reason = "because"', 'reason = "a\\tb"'),  # a tab would break the TSV
        ]
        for text in bad:
            with self.assertRaises(ConfigError, msg=text):
                load_text(HEAD + text)

    def test_approved_new_id(self):
        cat = load_text(HEAD + entry(11, extra='approved = "OB-00 2026-10-25 https://example/1"\n'))
        self.assertEqual(cat.ids(), [11])

    def test_512_cap(self):
        head = "[catalog]\nfrozen_baseline = [" + ", ".join(str(i) for i in range(1, 515)) + "]\n"
        with self.assertRaises(ConfigError):
            load_text(head + "".join(entry(i, basis="override") for i in range(1, 514)))


class Render(unittest.TestCase):
    def setUp(self):
        self.cat = load_text(HEAD + entry(9) + entry(2, basis="override") + entry(3, lst="no_custom_starts", basis="override", klass="config"))

    def test_keys_sorted(self):
        self.assertEqual(catalog.render_keys(self.cat),
                         "AiPlayerbot.QuestFeasibility.Blocklist = 2,9\n"
                         "AiPlayerbot.QuestFeasibility.BlocklistWhileNoCustomStarts = 3\n")

    def test_tsv_deterministic(self):
        a, b = catalog.render_tsv(self.cat), catalog.render_tsv(self.cat)
        self.assertEqual(a, b)
        self.assertEqual(a.splitlines()[0].split("\t"), list(catalog.TSV_COLUMNS))
        self.assertEqual([ln.split("\t")[0] for ln in a.splitlines()[1:]], ["2", "9", "3"])

    def test_lint(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            tsv, keys, prof = d / "q.tsv", d / "q.keys", d / "overlay.conf"
            self.assertEqual(len(catalog.lint(self.cat, tsv, keys, None)), 2)   # both missing
            tsv.write_text(catalog.render_tsv(self.cat), encoding="utf-8")
            keys.write_text(catalog.render_keys(self.cat), encoding="utf-8")
            prof.write_text("# x\n" + catalog.render_keys(self.cat) + "Other = 1\n", encoding="utf-8")
            self.assertEqual(catalog.lint(self.cat, tsv, keys, prof), [])
            prof.write_text("AiPlayerbot.QuestFeasibility.Blocklist = 2,9,10\n"
                            "AiPlayerbot.QuestFeasibility.BlocklistWhileNoCustomStarts = 3\n", encoding="utf-8")
            self.assertEqual(len(catalog.lint(self.cat, tsv, keys, prof)), 1)
            prof.write_text("AiPlayerbot.QuestFeasibility.Blocklist = 2,9\n", encoding="utf-8")
            self.assertEqual(len(catalog.lint(self.cat, tsv, keys, prof)), 1)   # a key line missing
            keys.write_text("stale\n", encoding="utf-8")
            self.assertTrue(any("stale" in p for p in catalog.lint(self.cat, tsv, keys, None)))


def world():
    """One quest per rule (1-8), a plain quest (9) for the override and the candidates, quest 10 missing."""
    con = empty_db()
    insert(con, "creature_template", entry=500, name="Spawned")
    insert(con, "creature_template", entry=501, name="Ghost")
    insert(con, "creature", guid=1, id=500, map=0)
    for e, kw in [
        (1, {"Type": 41}),                                   # PVP_BG
        (2, {}),                                             # NO_GIVER_NO_ENDER
        (3, {}),                                             # ENDER_UNSPAWNED
        (4, {}),                                             # GIVER_UNSPAWNED
        (5, {"ReqCreatureOrGOId1": 501}),                    # CREDIT_UNSPAWNED
        (6, {"ReqItemId1": 9001}),                           # ITEM_NO_SOURCE
        (7, {}),                                             # AT_ONLY
        (8, {"SuggestedPlayers": 3}),                        # GROUP
        (9, {"ReqItemId1": 9002, "ReqCreatureOrGOId1": 500}),  # a sourced item, a spawned target
    ]:
        insert(con, "quest_template", entry=e, Title=f"Quest {e}", Method=2, **kw)
    insert(con, "creature_loot_template", entry=500, item=9002, mincountOrRef=1)
    for q in (1, 3, 5, 6, 7, 8, 9):
        insert(con, "creature_questrelation", id=500, quest=q)
    insert(con, "creature_questrelation", id=501, quest=4)
    for q in (1, 4, 5, 6, 7, 8, 9):   # quest 2 has no rows, quest 3 only the unspawned ender
        insert(con, "creature_involvedrelation", id=500, quest=q)
    insert(con, "creature_involvedrelation", id=501, quest=3)
    insert(con, "areatrigger_involvedrelation", id=88, quest=7)
    insert(con, "quest_template", entry=20, Title="Another PvP", Method=2, Type=41)   # a candidate
    con.commit()
    return SqliteRunner.from_connection(con)


RULES = ["PVP_BG", "NO_GIVER_NO_ENDER", "ENDER_UNSPAWNED", "GIVER_UNSPAWNED", "CREDIT_UNSPAWNED", "ITEM_NO_SOURCE",
         "AT_ONLY", "GROUP"]


class Check(unittest.TestCase):
    def test_each_rule_matches_its_quest_only(self):
        runner = world()
        for i, rule in enumerate(RULES, start=1):
            _, rows = runner.query(catalog.fact_sql(FACTS[rule], BINDING, MACROS, list(range(1, 10))))
            self.assertIn((str(i),), rows, rule)
            self.assertNotIn(("9",), rows, rule)

    def test_pass_and_candidates(self):
        text = HEAD + "".join(entry(i, rule=r) for i, r in enumerate(RULES, start=1)) + entry(9, basis="override")
        res = catalog.check(world(), BINDING, MACROS, load_text(text), FACTS)
        self.assertEqual(res.problems, [])
        self.assertIn(("PVP_BG", 20), res.candidates)
        self.assertNotIn(("PVP_BG", 1), res.candidates)

    def test_rule_gone_and_missing(self):
        text = HEAD + entry(9, rule="GROUP") + entry(10, basis="override")
        res = catalog.check(world(), BINDING, MACROS, load_text(text), FACTS, candidates=False)
        self.assertEqual(sorted(r[5] for r in res.rows), ["missing", "rule_gone"])
        self.assertTrue(res.failing())

    def test_write_check(self):
        text = HEAD + entry(1)
        res = catalog.check(world(), BINDING, MACROS, load_text(text), FACTS)
        with tempfile.TemporaryDirectory() as d:
            catalog.write_check(res, Path(d))
            self.assertIn("1\tblocklist\trule\tPVP_BG\t", (Path(d) / "catalog-check.tsv").read_text(encoding="utf-8"))
            self.assertIn("PVP_BG: 1", (Path(d) / "catalog-summary.txt").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
