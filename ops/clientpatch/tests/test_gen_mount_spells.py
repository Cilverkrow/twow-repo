"""tools/gen_mount_spells.py: the Spell delta of the player mount spells (#295)."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

from synth import ROOT, binding

from clientpatch.delta import read_ops

SPEC = importlib.util.spec_from_file_location("gen_mount_spells", ROOT / "tools" / "gen_mount_spells.py")
GEN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GEN)

HEAD = "id,section,family,name\n"
SAMPLE = HEAD + (
    "458,text,1,Brown Horse\n"
    "16082,text,1,Palomino Stallion\n"
    "16082,points,1,Palomino Stallion\n"
    "17229,text,2-speed100,Winterspring Frostsaber\n"
    "36660,text,2,\"Anu'relos, Flame's Guidance\"\n"
)

# The W2b migration in miniature, statement shapes as in twow-core 20261002212000.
SQL = """\
-- Comment lines are skipped, `entry` IN (99999); and their semicolons too.
CREATE TABLE IF NOT EXISTS `spell_template_bak_295` LIKE `spell_template`;
INSERT IGNORE INTO `spell_template_bak_295`
SELECT * FROM `spell_template`
 WHERE `effectApplyAuraName1` = 78 AND `entry` IN (
  458, 16082, 17229, 36660
 );
UPDATE `spell_template` SET `effectBasePoints2` = 59
 WHERE `effectApplyAuraName2` = 32 AND `effectBasePoints2` = 99 AND `entry` IN (
  16082
 );
UPDATE `spell_template`
   SET `auraDescription` = 'Speed scales with your Riding skill: +60% (75), +100% (150 and higher).'
 WHERE `auraDescription` IN ('Speed scales with your Riding skill.', 'Increases speed based on your Riding skill.')
   AND `entry` IN (
  458, 16082
 );
UPDATE `spell_template`
   SET `auraDescription` = 'Speed scales with your Riding skill: +100% (up to 150), +140% (225), +180% (300).'
 WHERE `auraDescription` IN ('Speed scales with your Riding skill.', 'Increases speed based on your Riding skill.')
   AND `entry` IN (
  17229
 );
UPDATE `spell_template`
   SET `auraDescription` = REPLACE(`auraDescription`, 'Increases speed based on Riding skill.',
       'Speed scales with your Riding skill: +60% (75), +100% (150), +140% (225), +180% (300).')
 WHERE `auraDescription` LIKE 'Increases speed based on Riding skill.%' AND `entry` IN (
  36660
 );
CREATE TEMPORARY TABLE IF NOT EXISTS `tmp_check_295_w2b` (`ok` TINYINT(1) NOT NULL CHECK (`ok` = 1));
INSERT INTO `tmp_check_295_w2b` (`ok`)
SELECT (SELECT COUNT(*) FROM `spell_template` WHERE `effectBasePoints2` = 59 AND `entry` IN (
  16082
 )) = 1;
"""


def ops(text: str) -> list[dict]:
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "0001_x.csv"
        p.write_text(text, encoding="utf-8")
        return [row for _, row in read_ops(p)]


class GenMountSpells(unittest.TestCase):
    def test_committed_mount_delta_is_current(self):
        # changes/Spell/0295_mount_spells.csv is generated, header included; a hand edit or a
        # stale input list shows up here.
        committed = (ROOT / "changes" / "Spell" / "0295_mount_spells.csv").read_text(encoding="utf-8")
        fresh = GEN.generate((ROOT / "tools" / "inputs" / "295-mount-spells.csv").read_text(encoding="utf-8"))
        self.assertEqual(committed, fresh)

    def test_rows_by_section_then_id_with_family_notes(self):
        text = GEN.generate(SAMPLE)
        self.assertEqual(text.splitlines()[0], "op,key,field,value,note")
        self.assertIn("Same 4 spells as the migration's list.", text)
        rows = ops(text)
        points = ("EffectBasePoints[1]", "sql:spell_template.effectBasePoints2")
        aura = ("AuraDescription_lang_enUS", "sql:spell_template.auraDescription")
        self.assertEqual([(r["op"], r["key"], r["field"], r["value"], r["note"]) for r in rows], [
            ("set", "16082", *points, "Palomino Stallion: family 1, aura-32 value 100 -> 60 (CV-14)"),
            ("set", "458", *aura, "Brown Horse: family 1 (CV-14)"),
            ("set", "16082", *aura, "Palomino Stallion: family 1 (CV-14)"),
            ("set", "17229", *aura, "Winterspring Frostsaber: family 2, speed-100 flag (CV-14)"),
            ("set", "36660", *aura, "Anu'relos, Flame's Guidance: family 2 (CV-14)"),
        ])
        columns = {c.name for c in binding("Spell").columns}
        for dbc, _ in GEN.SECTIONS.values():
            self.assertIn(dbc, columns)

    def test_bad_input_is_refused(self):
        for body in ("",                                # no spells
                     "7,text,3,x\n",                    # unknown family
                     "7,base,1,x\n",                    # unknown section
                     "7,points,2,x\n7,text,2,x\n",      # 100 -> 60 makes a spell family 1
                     "7,points,1,x\n",                  # points line without a text line
                     "7,points,1,x\n7,text,2,x\n",      # ... or with the text of another family
                     "7,text,1,x\n7,text,2,x\n",        # twice in one section
                     "7,points,1,x\n7,text,1,y\n",      # two names for one spell
                     "7,text,1,\n",                     # no name
                     "7,text,1, \n",                    # blank name
                     "7,text,1,Caf%s\n" % chr(0xE9),    # not ASCII
                     "7,text,1\n",                      # field missing
                     "7,text,1,x,y\n",                  # field too many
                     "65536,text,1,x\n",                # not a 16-bit spell ID
                     "x,text,1,x\n"):                   # not a number
            with self.assertRaises(SystemExit, msg=body):
                GEN.generate(HEAD + body)
        with self.assertRaises(SystemExit):
            GEN.generate("id,family,section,name\n7,1,text,x\n")

    def test_core_check_compares_ids_points_and_families(self):
        with tempfile.TemporaryDirectory() as core:
            with self.assertRaises(FileNotFoundError):
                GEN.check_core(GEN.load(SAMPLE), core)
            migration = Path(core) / GEN.MIGRATION
            migration.parent.mkdir(parents=True)
            migration.write_text(SQL, encoding="utf-8")

            def errors(text):
                return GEN.check_core(GEN.load(text), core)

            self.assertEqual(errors(SAMPLE), [])
            self.assertEqual(errors(SAMPLE.replace("458,text,1,Brown Horse\n", "")),
                             ["spell 458 is in the migration but not in the delta"])
            self.assertEqual(errors(SAMPLE + "459,text,1,Gray Wolf\n"),
                             ["spell 459 is in the delta but not in the migration"])
            self.assertEqual(errors(SAMPLE.replace("16082,points,1,Palomino Stallion\n", "")),
                             ["spell 16082: aura-32 value 100 -> 60 in the migration only"])
            self.assertEqual(errors(SAMPLE.replace("17229,text,2-speed100", "17229,text,2")),
                             ["spell 17229: text family 2-speed100 in the migration, 2 in the delta"])
            # A text update the generator does not know stops the check instead of passing it.
            migration.write_text(SQL.replace("+100% (150 and higher).", "+100%."), encoding="utf-8")
            with self.assertRaises(ValueError):
                errors(SAMPLE)

    def test_cli_writes_and_checks(self):
        with tempfile.TemporaryDirectory() as tmp:
            spells, delta = Path(tmp) / "spells.csv", Path(tmp) / "0295_x.csv"
            spells.write_text(SAMPLE, encoding="utf-8")
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(GEN.main(["--spells", str(spells), "--out", str(delta)]), 0)
                self.assertEqual(GEN.main(["--spells", str(spells), "--check", str(delta)]), 0)
                delta.write_text(delta.read_text(encoding="utf-8").replace("Brown Horse", "Brown Pony"),
                                 encoding="utf-8")
                self.assertEqual(GEN.main(["--spells", str(spells), "--check", str(delta)]), 1)
            self.assertEqual(delta.read_text(encoding="utf-8").count("Brown Pony"), 1)
            self.assertIn("MOUNTSPELLS=FAIL spells=4 points=1 errors=1 core=skipped", out.getvalue())


if __name__ == "__main__":
    unittest.main()
