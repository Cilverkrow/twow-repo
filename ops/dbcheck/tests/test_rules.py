"""Every rule against the synthetic world: one positive and one negative case each."""

import unittest

from synth import BINDING, MACROS, RULES, world

from dbcheck import engine
from dbcheck.expected import Boss, Expected, Quest
from dbcheck.runner import SqliteRunner


def expected():
    return Expected(
        id="synthetic", name="Synthetic", source="synthetic", source_date="2026-09-29",
        allow_elsewhere=[],
        bosses=[
            Boss(100, "Boss Alpha", False, [
                "Sword of Tests", "Helm of O'Brien", "Ring via Ref", "Cloak Elsewhere", "Call of the Wild", "Nonexistent Thing",
            ]),
            Boss(101, "Boss Beta", False, ["Sword of Tests"]),
            Boss(999, "Boss Missing", False, []),
        ],
        quests=[Quest(10, "Quest Ten", 300, 300), Quest(12, "Quest Twelve", 301, None), Quest(99, "Quest Ninety-nine", None, None)],
        sha256="0" * 64, path="synthetic.toml",
    )


class Rules(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.run_ = engine.run(SqliteRunner.from_connection(world()), BINDING, RULES, MACROS, [expected()])

    def rows(self, rule, subject_part=""):
        out = []
        for r in self.run_.results:
            if r.rule.name == rule and subject_part in r.subject:
                out.extend(r.rows)
        return out

    def names(self, rule, subject_part="", col=0):
        return sorted(str(r[col]) for r in self.rows(rule, subject_part))

    def test_quest_without_starter(self):
        self.assertEqual(self.names("quest_no_giver"), ["11"])

    def test_retired_quests_are_not_flagged(self):
        self.assertNotIn("15", self.names("quest_no_giver") + self.names("quest_no_ender"))

    def test_quest_without_turn_in(self):
        self.assertEqual(self.names("quest_no_ender"), ["12"])

    def test_broken_chain_lists_each_field_and_ignores_the_sign_of_prev(self):
        got = sorted((r[0], r[2], r[3]) for r in self.rows("quest_chain_broken"))
        self.assertEqual(got, [("13", "chain", "997"), ("13", "next", "998"), ("13", "prev", "999")])

    def test_expected_quest_missing(self):
        self.assertEqual(self.names("quest_expected_missing"), ["99"])

    def test_expected_quest_giver_and_ender(self):
        self.assertEqual(self.names("quest_giver_mismatch"), ["12"])  # 12 is started by 300, not 301
        self.assertEqual(self.names("quest_ender_mismatch"), [])  # quest 10 matches; 12 has no expected ender

    def test_boss_unknown_and_no_spawn(self):
        self.assertEqual(self.names("boss_unknown"), ["999"])
        self.assertEqual(self.names("boss_no_spawn"), ["101"])

    def test_boss_without_spawn_is_found_without_an_expected_list(self):
        self.assertEqual(self.names("boss_no_spawn_any"), ["101"])  # 102 has no loot, 100 is spawned

    def test_missing_loot_follows_references_and_ignores_case(self):
        missing = self.names("boss_loot_missing", "Boss Alpha")
        self.assertEqual(missing, ["Call of the Wild", "Cloak Elsewhere"])  # "Ring via Ref" is found through the reference

    def test_unknown_loot_item(self):
        self.assertEqual(self.names("boss_loot_item_unknown", "Boss Alpha"), ["Nonexistent Thing"])

    def test_extra_loot_is_info(self):
        self.assertEqual(self.names("boss_loot_extra", "Boss Alpha", col=1), ["Unnamed Extra"])
        self.assertEqual(RULES["boss_loot_extra"].severity, "info")

    def test_foreign_loot_id(self):
        row = self.rows("loot_foreign", "Boss Alpha")
        self.assertEqual([(r[1], r[2]) for r in row], [("Cloak Elsewhere", "200")])

    def test_allow_elsewhere_silences_the_foreign_loot_rule(self):
        exp = expected()
        exp.allow_elsewhere = ["cloak elsewhere"]
        run = engine.run(SqliteRunner.from_connection(world()), BINDING, RULES, MACROS, [exp], {"loot_foreign"})
        self.assertEqual([r for res in run.results for r in res.rows], [])

    def test_item_without_source(self):
        self.assertEqual(self.names("item_no_source", col=1), ["Call of the Wild", "Orphan Epic"])
        # 1001-1003 and 1008 drop, 1004 drops from trash, 1007 is sold: only 1005 and 1006 have no source.

    def test_empty_expected_list_skips_name_rules_instead_of_flagging_everything(self):
        skipped = [r for r in self.run_.results if r.rule.name == "boss_loot_missing" and "Boss Missing" in r.subject]
        self.assertTrue(skipped and skipped[0].skipped)

    def test_failing_ignores_info(self):
        run = engine.run(SqliteRunner.from_connection(world()), BINDING, RULES, MACROS, [expected()], {"boss_loot_extra"})
        self.assertEqual(run.failing(), [])


if __name__ == "__main__":
    unittest.main()
