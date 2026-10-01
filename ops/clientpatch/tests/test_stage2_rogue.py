"""Stage 2, rogue (#367): the committed deltas against a synthetic base and a
synthetic spell_template export. No client file and no database are used."""

import csv
import importlib.util
import tempfile
import unittest
from pathlib import Path

from synth import ROOT, binding, pack

from clientpatch import consistency
from clientpatch.delta import Touched, apply_file, list_files, read_ops
from clientpatch.sqlsrc import SqlData, load_sources
from clientpatch.wdbc import Table

SPEC = importlib.util.spec_from_file_location("gen_spell_mirror", ROOT / "tools" / "gen_spell_mirror.py")
GEN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GEN)

CHANGES = ROOT / "changes"
INPUT = ROOT / "tools" / "inputs" / "367-rogue-spells.csv"


def apply_rogue(table, sql):
    """Apply only this change's deltas (0367_*). Other stage-2 changes (the
    shaman's 0357_*) need rows the synthetic export does not carry; the full
    set runs in the real build against the real server export."""
    touched = Touched()
    files = [p for p in list_files(CHANGES, table.binding.dbc) if p.name.startswith("0367_")]
    for p in files:
        apply_file(table, p, sql, touched)
    return touched, files

# OB-20 (#367 issuecomment-5858585355): aura IDs per talent, owner rows/columns 1-based.
OWNER_LINE = {
    # (tab, row, col): rank spells
    (182, 1, 4): [61151, 61152, 61153, 61154],
    (182, 3, 4): [61155, 61156],
    (182, 5, 4): [61157],
    (182, 7, 1): [61158],
    (182, 7, 3): [61159],
    (181, 1, 1): [61160, 61161, 61162, 61163, 61164],
    (181, 1, 4): [61165, 61166, 61167, 61168, 61169],
    (181, 2, 4): [61170, 61171, 61172],
    (181, 4, 4): [61173, 61174, 61175],
    (181, 6, 1): [61176, 61177, 61178],
    (181, 7, 1): [61179],
    (181, 6, 4): [61180, 61181, 61182],
    (181, 7, 4): [61183],
    (183, 1, 1): [61184, 61185, 61186, 61187],
    (183, 6, 4): [61188],
    (183, 7, 3): [61189, 61190, 61191],
}
# Free slots in Turtle's Combat tree (OB-20 review of #386, live Talent.dbc), 1-based.
FREE_COMBAT = {(1, 1), (1, 4), (2, 4), (3, 3), (4, 4), (6, 1), (6, 4), (7, 1), (7, 3), (7, 4)}

# Existing Turtle talents the owner's arrows start from (V-2; IDs from OB-20,
# checked by OB-15 against the client Talent.dbc of base turtle-1.18.1-enUS).
EXISTING_PREREQS = {
    133: {"TabID": 182, "TierID": 1, "ColumnIndex": 3, "ranks": [14165, 0, 0]},  # Improved Blade Tactics
    142: {"TabID": 182, "TierID": 4, "ColumnIndex": 2, "ranks": [14177]},         # Cold Blood
    117: {"TabID": 181, "TierID": 2, "ColumnIndex": 3, "ranks": [13983, 0, 0]},  # Setup
}


def rows_of(path: Path) -> list[dict]:
    return [row for _, row in read_ops(path)]


def talents() -> dict[int, dict]:
    out: dict[int, dict] = {}
    for r in rows_of(CHANGES / "Talent" / "0367_rogue_talents.csv"):
        key = int(r["key"])
        if r["op"] == "insert":
            out[key] = {"ranks": {}}
        else:
            out[key][r["field"]] = int(r["value"])
    for t in out.values():
        t["ranks"] = [t[f"SpellRank[{i}]"] for i in range(9) if f"SpellRank[{i}]" in t]
    return out


class RogueTalentContract(unittest.TestCase):
    def test_owner_line_exactly(self):
        got = {(t["TabID"], t["TierID"] + 1, t["ColumnIndex"] + 1): t["ranks"] for t in talents().values()}
        self.assertEqual(got, OWNER_LINE)

    def test_talent_ids_follow_the_first_rank(self):
        for talent_id, t in talents().items():
            # talent ID = first rank - 81000 in the numbering before #455 (spells moved by -28999)
            self.assertEqual(talent_id, t["ranks"][0] + 28999 - 81000)

    def test_combat_talents_use_free_slots_only(self):
        for t in talents().values():
            if t["TabID"] == 181:
                self.assertIn((t["TierID"] + 1, t["ColumnIndex"] + 1), FREE_COMBAT)

    def test_prerequisites_point_up_the_same_tree(self):
        all_talents = talents()
        for t in all_talents.values():
            if "PrereqTalent[0]" in t:
                pre = all_talents.get(t["PrereqTalent[0]"]) or EXISTING_PREREQS[t["PrereqTalent[0]"]]
                self.assertEqual(pre["TabID"], t["TabID"])
                # Down arrow from a higher tier, or a right/left arrow from the
                # neighbouring column of the same tier (1.12 talent frame).
                same_tier_neighbour = (pre["TierID"] == t["TierID"]
                                       and abs(pre["ColumnIndex"] - t["ColumnIndex"]) == 1)
                self.assertTrue(pre["TierID"] < t["TierID"] or same_tier_neighbour)
                self.assertLess(t["PrereqRank[0]"], len(pre["ranks"]))

    def test_every_rank_spell_gets_a_client_row(self):
        mirrored = {int(r["id"]) for r in csv.DictReader(INPUT.read_text(encoding="utf-8").splitlines())}
        for t in talents().values():
            self.assertTrue(set(t["ranks"]) <= mirrored)
        # kit 61141-61147, talent line and helpers 61151-61194, poison ranks 61201-61208,
        # recipes and trainer spells of P-1/P-2 61209-61220
        expected = set(range(61141, 61148)) | set(range(61151, 61195)) | set(range(61201, 61221))
        self.assertEqual(mirrored, expected)

    def test_enchantments_fire_the_mirrored_poison_procs(self):
        rows = rows_of(CHANGES / "SpellItemEnchantment" / "0367_agitating_poison_ranks.csv")
        procs = {int(r["key"]): int(r["value"]) for r in rows if r["field"] == "EffectArg[0]"}
        self.assertEqual(procs, {3060: 61201, 3061: 61202, 3062: 61203, 3063: 61204})


class RogueDeltasEndToEnd(unittest.TestCase):
    """Apply the committed deltas to synthetic base tables and run the server rules."""

    RULES = ("spell-matches-server", "talent-ranks-on-server", "enchant-procs-on-server",
             "skill-line-ability-matches-server")

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        spell_b = binding("Spell")
        spells = list(csv.DictReader(INPUT.read_text(encoding="utf-8").splitlines()))
        sources = sorted({int(s["copy_from"]) for s in spells})
        self.tables = {
            "Spell": Table.from_bytes(pack(spell_b, [{"ID": s, "Name_lang_enUS": "base"} for s in sources]), spell_b),
            "Talent": Table.from_bytes(pack(binding("Talent"), [{"ID": 1, "TabID": 181}]), binding("Talent")),
            "SpellItemEnchantment": Table.from_bytes(
                pack(binding("SpellItemEnchantment"), [{"ID": 3006, "Effect[0]": 1, "EffectArg[0]": 45613}]),
                binding("SpellItemEnchantment")),
            "SkillLineAbility": Table.from_bytes(pack(binding("SkillLineAbility"), [{"ID": 1, "SkillLine": 38}]),
                                                 binding("SkillLineAbility")),
        }
        # P-1/P-2 skill_line_ability rows as the core migration writes them.
        sla = ["id\tskill_id\tspell_id\trace_mask\tclass_mask\treq_skill_value\tsuperseded_by_spell\t"
               "learn_on_get_skill\tmax_value\tmin_value"]
        for spell, skill, sup, hi, lo in ((61141, 38, 0, 0, 0), (61143, 38, 61144, 0, 0), (61144, 38, 61145, 0, 0),
                                          (61145, 38, 0, 0, 0), (61209, 40, 0, 175, 125), (61210, 40, 0, 225, 175),
                                          (61211, 40, 0, 275, 225), (61212, 40, 0, 325, 275)):
            # id = spell - 60000: the server column is smallint unsigned (#367, 2026-09-30).
            sla.append("\t".join(str(v) for v in (spell + 28999 - 60000, skill, spell, 0, 8, 1, sup, 0, hi, lo)))
        (self.tmp / "skill_line_ability.tsv").write_text("\n".join(sla) + "\n", encoding="utf-8")
        # A server export with a distinct value in every mirrored column.
        kinds = {c.name: c.kind for c in spell_b.columns}
        pairs = GEN.pairs(ROOT)
        header = ["entry"] + [sql for sql, _ in pairs]
        lines = ["\t".join(header)]
        for n, s in enumerate(spells):
            spell = int(s["id"])
            values = [str(spell)]
            for i, (sql, dbc) in enumerate(pairs):
                kind = kinds[dbc]
                if kind == "string":
                    values.append(f"{sql} of {spell}")
                elif kind == "float":
                    values.append(f"{(n + i) % 7}.5")
                else:
                    values.append(str((spell + i) % 50000))
            lines.append("\t".join(values))
        (self.tmp / "spell_template.tsv").write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.sql = SqlData(load_sources(ROOT / "sql" / "sources.toml"), self.tmp)

    def test_rules_pass_on_the_patched_tables(self):
        touched = {}
        for dbc, table in self.tables.items():
            touched[dbc], files = apply_rogue(table, self.sql)
            self.assertTrue(files, dbc)
        rules = [r for r in consistency.load_rules(ROOT / "consistency") if r.id in self.RULES]
        self.assertEqual(len(rules), len(self.RULES))
        findings = consistency.run(rules, self.tables, self.sql, touched)
        self.assertEqual(consistency.blocking(findings), [])
        self.assertEqual(self.tables["Spell"].get((61151,), "Description_lang_enUS"), "description of 61151")
        self.assertEqual(self.tables["Talent"].get((9178,), "PrereqTalent[0]"), 9175)
        self.assertEqual(self.tables["SkillLineAbility"].get((30142,), "SupercededBySpell"), 61144)
        self.assertEqual(self.tables["SkillLineAbility"].get((30208,), "SkillLine"), 40)

    def test_a_missing_server_spell_is_caught(self):
        # Drop one rank spell from the export: the talent and spell rules must fail.
        path = self.tmp / "spell_template.tsv"
        path.write_text("\n".join(ln for ln in path.read_text().splitlines()
                                  if not ln.startswith("61169\t")) + "\n")
        self.sql = SqlData(load_sources(ROOT / "sql" / "sources.toml"), self.tmp)
        with self.assertRaises(Exception):
            for dbc, table in self.tables.items():
                apply_rogue(table, self.sql)


if __name__ == "__main__":
    unittest.main()
