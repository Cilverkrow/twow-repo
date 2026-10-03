"""tools/gen_spell_mirror.py: a Spell delta that mirrors spell_template."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

from synth import ROOT, binding

from clientpatch.delta import read_ops

SPEC = importlib.util.spec_from_file_location("gen_spell_mirror", ROOT / "tools" / "gen_spell_mirror.py")
GEN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GEN)


def ops(text: str) -> list[dict]:
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "0001_x.csv"
        p.write_text(text, encoding="utf-8")
        return [row for _, row in read_ops(p)]


class GenSpellMirror(unittest.TestCase):
    def test_every_rule_pair_is_mirrored(self):
        # The consistency rule and the mirror cannot drift apart: every column the
        # rule compares is written from the server export.
        pairs = dict((dbc, sql) for sql, dbc in GEN.pairs(ROOT))
        rows = ops(GEN.generate("id,copy_from,class_mask,note\n90150,12297,0,x\n"))
        written = {r["field"]: r["value"] for r in rows if r["op"] == "set"}
        for dbc, sql in pairs.items():
            self.assertEqual(written[dbc], "sql:spell_template.%s" % sql)

    def test_pairs_name_real_columns_on_both_sides(self):
        columns = {c.name for c in binding("Spell").columns}
        sql_columns = set()
        for sql, dbc in GEN.pairs(ROOT):
            self.assertIn(dbc, columns)
            self.assertNotIn(sql, sql_columns)
            sql_columns.add(sql)
        # The texts and the icon are server values too (single source of truth).
        self.assertIn(("description", "Description_lang_enUS"), GEN.pairs(ROOT))
        self.assertIn(("spellIconId", "SpellIconID"), GEN.pairs(ROOT))

    def test_insert_copies_and_class_mask_is_split(self):
        rows = ops(GEN.generate("id,copy_from,class_mask,note\n7,3,0x100000002,n\n"))
        self.assertEqual(rows[0], {"op": "insert", "key": "7", "field": "", "value": "copy:3", "note": "n"})
        mask = {r["field"]: r["value"] for r in rows if r["field"].startswith("SpellClassMask")}
        self.assertEqual(mask, {"SpellClassMask[0]": "2", "SpellClassMask[1]": "1"})

    def test_copy_keeps_the_class_mask(self):
        rows = ops(GEN.generate("id,copy_from,class_mask,note\n7,3,copy,n\n"))
        self.assertFalse(any(r["field"].startswith("SpellClassMask") for r in rows))

    def test_bad_input_is_refused(self):
        for text in ("id,copy_from,class_mask,note\n",
                     "id,copy_from,class_mask,note\n7,3,0,a\n7,4,0,b\n",
                     "id,copy_from,class_mask,note\n7,3,%d,a\n" % (1 << 64)):
            with self.assertRaises(SystemExit):
                GEN.generate(text)

    def test_committed_rogue_delta_is_current(self):
        # changes/Spell/0367_rogue_spells.csv is generated; a hand edit or a stale
        # input list shows up here.
        committed = (ROOT / "changes" / "Spell" / "0367_rogue_spells.csv").read_text(encoding="utf-8")
        body = [ln for ln in committed.splitlines() if not ln.startswith("#")]
        fresh = GEN.generate((ROOT / "tools" / "inputs" / "367-rogue-spells.csv").read_text(encoding="utf-8"))
        self.assertEqual(body, fresh.splitlines())

    def test_committed_0484_delta_is_current(self):
        # #484 train 9: Riposte Flow strikes and Charged Stormstrike ranks 2-4, a
        # separate input so the #367 key set (test_stage2_rogue) stays unchanged.
        committed = (ROOT / "changes" / "Spell" / "0484_talent_spells.csv").read_text(encoding="utf-8")
        body = [ln for ln in committed.splitlines() if not ln.startswith("#")]
        fresh = GEN.generate((ROOT / "tools" / "inputs" / "484-spells.csv").read_text(encoding="utf-8"))
        self.assertEqual(body, fresh.splitlines())
        inserted = {int(r["key"]) for r in ops(fresh) if r["op"] == "insert"}
        self.assertEqual(inserted, set(range(61221, 61226)))


if __name__ == "__main__":
    unittest.main()
