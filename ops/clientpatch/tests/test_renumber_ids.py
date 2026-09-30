"""tools/renumber_ids.py: field-aware renumbering of spell and enchantment IDs (#455)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import renumber_ids  # noqa: E402

SPELLS = {90141: 61142, 90200: 61201}
ENCHANTS = {90141: 3060}
HEADER = "op,key,field,value,note\n"


class RenumberIds(unittest.TestCase):
    def test_same_number_as_enchant_and_spell(self):
        # 90141 is both a spell and an enchantment: the key follows the enchant map,
        # the EffectArg value the spell map.
        text = HEADER + "insert,90141,,copy:3006,rank 1\nset,90141,EffectArg[0],90200,proc\n"
        out = renumber_ids.rewrite_delta(text, ENCHANTS, SPELLS)
        self.assertEqual(out, HEADER + "insert,3060,,copy:3006,rank 1\nset,3060,EffectArg[0],61201,proc\n")

    def test_spell_keys_and_talent_ranks(self):
        spell = renumber_ids.rewrite_delta(HEADER + "set,90141,SpellIconID,sql:spell_template.spellIconId,\n",
                                           SPELLS, SPELLS)
        self.assertEqual(spell, HEADER + "set,61142,SpellIconID,sql:spell_template.spellIconId,\n")
        talent = renumber_ids.rewrite_delta(HEADER + "set,9001,SpellRank[1],90200,\nset,9001,TierID,1,\n", {}, SPELLS)
        self.assertEqual(talent, HEADER + "set,9001,SpellRank[1],61201,\nset,9001,TierID,1,\n")

    def test_comments_quotes_and_line_endings_survive(self):
        text = HEADER + "# kit 90141-90200\r\nset,90141,Name_lang_enUS,\"Spit, rank 1\",\"a, b\"\r\n"
        out = renumber_ids.rewrite_delta(text, SPELLS, SPELLS)
        self.assertEqual(out, HEADER + "# kit 61142-61201\r\nset,61142,Name_lang_enUS,\"Spit, rank 1\",\"a, b\"\r\n")
        self.assertEqual(renumber_ids.rewrite_delta(out, SPELLS, SPELLS), out)

    def test_inputs(self):
        text = "ID,SpellRank_0,SpellRank_1,PrereqTalent_0,note\n9001,90141,90200,0,x\n"
        self.assertEqual(renumber_ids.rewrite_input(text, SPELLS),
                         "ID,SpellRank_0,SpellRank_1,PrereqTalent_0,note\n9001,61142,61201,0,x\n")


if __name__ == "__main__":
    unittest.main()
