"""Every rule against the synthetic world: one positive and one negative case each."""

import unittest

from synth import BINDING, MACROS, RULES, world

from dbcheck import engine
from dbcheck.expected import Boss, Expected, Quest, Scripted, Summoned
from dbcheck.runner import SqliteRunner


def expected():
    return Expected(
        id="synthetic", name="Synthetic", source="synthetic", source_date="2026-09-29",
        allow_elsewhere=[],
        bosses=[
            Boss(100, "Boss Alpha", False, [
                "Sword of Tests", "Helm of O'Brien", "Ring via Ref", "Nested Ring", "Cloak Elsewhere", "Call of the Wild",
                "Nonexistent Thing", "Hidden Ref Item",
            ], 3),
            Boss(101, "Boss Beta", False, ["Sword of Tests"], 0),
            Boss(103, "Boss Delta", True, []),
            Boss(104, "Boss Epsilon", True, []),
            Boss(105, "Boss Zeta", False, []),  # spawned only through creature.id2
            Boss(999, "Boss Missing", False, []),
        ],
        quests=[Quest(10, "Quest Ten", 300, 300), Quest(12, "Quest Twelve", 301, None), Quest(99, "Quest Ninety-nine", None, None)],
        scripted=[Scripted(17, "eluna", True, False), Scripted(18, "script", False, True), Scripted(22, "retired", True, True)],
        summoned=[Summoned(104, "cpp")],
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

    # quests

    def test_quest_without_starter(self):
        # 11 has nothing; 16 is only named in NextQuestInChain, which does not count as a starter.
        self.assertEqual(self.names("quest_no_giver"), ["11", "16"])

    def test_retired_and_scripted_quests_are_not_flagged(self):
        flagged = self.names("quest_no_giver") + self.names("quest_no_ender") + self.names("quest_script_started")
        for quest in ("15", "20", "21"):  # title patterns: [DEPRECATED]%, %Dummy%, %[Deprecated]
            self.assertNotIn(quest, flagged)
        self.assertNotIn("17", self.names("quest_no_giver"))  # the list says a script starts it
        self.assertNotIn("22", flagged)  # the list retires it by id

    def test_method_zero_quests_are_reported_separately(self):
        self.assertEqual(self.names("quest_script_started"), ["19"])
        self.assertNotIn("19", self.names("quest_no_giver"))

    def test_quest_without_turn_in(self):
        # 18 is turned in by a script and named in the list; 19 has no turn-in at all.
        self.assertEqual(self.names("quest_no_ender"), ["12", "19"])

    def test_without_the_list_scripted_quests_are_findings_again(self):
        run = engine.run(SqliteRunner.from_connection(world()), BINDING, RULES, MACROS, [], {"quest_no_giver", "quest_no_ender"})
        flagged = sorted(str(r[0]) for res in run.results for r in res.rows)
        for quest in ("17", "18", "22"):
            self.assertIn(quest, flagged)

    def test_unspawned_givers_and_turn_in_npcs(self):
        self.assertEqual([(r[0], r[2]) for r in self.rows("quest_giver_unspawned")], [("301", "1")])  # 300 spawns via id3
        self.assertEqual([(r[0], r[2]) for r in self.rows("quest_ender_unspawned")], [("302", "1")])

    def test_broken_chain_lists_each_field_and_ignores_the_sign_of_prev(self):
        got = sorted((r[0], r[2], r[3]) for r in self.rows("quest_chain_broken"))
        self.assertEqual(got, [("13", "chain", "997"), ("13", "next", "998"), ("13", "prev", "999")])

    def test_expected_quest_missing(self):
        self.assertEqual(self.names("quest_expected_missing"), ["99"])

    def test_expected_quest_giver_and_ender(self):
        self.assertEqual(self.names("quest_giver_mismatch"), ["12"])  # 12 is started by 300, not 301
        self.assertEqual(self.names("quest_ender_mismatch"), [])  # quest 10 matches; 12 has no expected ender

    # bosses and loot

    def test_boss_unknown_and_no_spawn(self):
        self.assertEqual(self.names("boss_unknown"), ["999"])
        self.assertEqual(self.names("boss_no_spawn"), ["101"])  # 105 spawns only through id2; 103 and 104 are spawn_optional

    def test_boss_rank(self):
        self.assertEqual([(r[0], r[2], r[3]) for r in self.rows("boss_rank_mismatch")], [("101", "3", "0")])

    def test_boss_without_spawn_is_found_without_an_expected_list(self):
        # 103 is summoned by a database script, 104 by C++ (named in the list), 105 spawns via id2, 102 has no loot.
        self.assertEqual(self.names("boss_no_spawn_any"), ["101"])
        run = engine.run(SqliteRunner.from_connection(world()), BINDING, RULES, MACROS, [], {"boss_no_spawn_any"})
        self.assertEqual(sorted(str(r[0]) for res in run.results for r in res.rows), ["101", "104"])

    def test_missing_loot_follows_nested_references_and_ignores_case(self):
        missing = self.names("boss_loot_missing", "Boss Alpha")
        # "Ring via Ref" is one reference level down, "Nested Ring" two levels down: both found.
        self.assertEqual(missing, ["Call of the Wild", "Cloak Elsewhere", "Hidden Ref Item"])

    def test_unknown_loot_item(self):
        self.assertEqual(self.names("boss_loot_item_unknown", "Boss Alpha"), ["Nonexistent Thing"])

    def test_extra_loot_is_info(self):
        self.assertEqual(self.names("boss_loot_extra", "Boss Alpha", col=1), ["Unnamed Extra"])
        self.assertEqual(RULES["boss_loot_extra"].severity, "info")

    def test_foreign_loot_id_direct_and_through_a_reference_group(self):
        row = self.rows("loot_foreign", "Boss Alpha")
        self.assertEqual(sorted((r[1], r[2]) for r in row), [("Cloak Elsewhere", "200"), ("Hidden Ref Item", "201")])

    def test_allow_elsewhere_silences_the_foreign_loot_rule(self):
        exp = expected()
        exp.allow_elsewhere = ["cloak elsewhere", "Hidden Ref Item"]
        run = engine.run(SqliteRunner.from_connection(world()), BINDING, RULES, MACROS, [exp], {"loot_foreign"})
        self.assertEqual([r for res in run.results for r in res.rows], [])

    def test_nested_reference_groups_are_listed(self):
        self.assertEqual([(r[0], r[1]) for r in self.rows("reference_loot_nested")], [("5", "6")])

    # items

    def test_item_without_source(self):
        # Sources counted: loot (creature, reference, skinning), vendor and vendor template, mail loot, quest start item.
        self.assertEqual(self.names("item_no_source", col=1), ["Call of the Wild", "Orphan Epic"])

    # engine

    def test_empty_expected_list_skips_name_rules_instead_of_flagging_everything(self):
        skipped = [r for r in self.run_.results if r.rule.name == "boss_loot_missing" and "Boss Missing" in r.subject]
        self.assertTrue(skipped and skipped[0].skipped)

    def test_failing_ignores_info(self):
        run = engine.run(SqliteRunner.from_connection(world()), BINDING, RULES, MACROS, [expected()], {"boss_loot_extra"})
        self.assertEqual(run.failing(), [])


if __name__ == "__main__":
    unittest.main()
