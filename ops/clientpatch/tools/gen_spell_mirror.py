#!/usr/bin/env python3
"""Write a Spell.dbc delta that mirrors server spells from spell_template.

Stage 2 adds client rows for spells that so far exist only on the server (bot
auras that become talent ranks, new player spells). The server stays the
single source of truth: every mapped column is written as
``sql:spell_template.<column>``, so a later value change needs no delta edit,
only a new export. The input is a small CSV:

    id,copy_from,class_mask,note
    61151,12297,0,Blindside rank 1 (#367)

- ``copy_from``: an existing client spell the new row starts from. It supplies
  what spell_template cannot: locale flags and the other locales. Use the
  spell the server row was cloned from.
- ``class_mask``: ``SpellClassMask`` (the server's 64-bit spellFamilyFlags,
  which one ``sql:`` value cannot split), as an integer, or ``copy`` to keep
  the value of ``copy_from``.
- ``note``: goes into every line's ``note`` column (issue, CV- entry).

The column pairs come from the ``spell-matches-server`` rule in
``consistency/server.toml`` plus EXTRA_PAIRS below, so the rule and the
mirror cannot drift apart. Every pair is checked against the Spell binding.

    python3 tools/gen_spell_mirror.py --spells spells.csv \\
        --out changes/Spell/0100_example.csv
"""
import argparse
import csv
import io
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# spell_template columns the rule does not compare but the client row needs
# (twow-core sql/base/tw_world_spell_template.sql -> Spell.toml).
EXTRA_PAIRS = [
    ("category", "Category"), ("castUI", "CastUI"), ("dispel", "DispelType"),
    ("mechanic", "Mechanic"), ("stances", "ShapeshiftMask"),
    ("stancesNot", "ShapeshiftExclude"), ("targets", "Targets"),
    ("targetCreatureType", "TargetCreatureType"),
    ("requiresSpellFocus", "RequiresSpellFocus"),
    ("casterAuraState", "CasterAuraState"), ("targetAuraState", "TargetAuraState"),
    ("interruptFlags", "InterruptFlags"), ("auraInterruptFlags", "AuraInterruptFlags"),
    ("channelInterruptFlags", "ChannelInterruptFlags"), ("procFlags", "ProcFlags"),
    ("maxLevel", "MaxLevel"), ("baseLevel", "BaseLevel"), ("spellLevel", "SpellLevel"),
    ("manCostPerLevel", "ManaCostPerLevel"), ("manaPerSecond", "ManaPerSecond"),
    ("manaPerSecondPerLevel", "ManaPerSecondPerLevel"),
    ("modelNextSpell", "ModalNextSpell"),
    ("totem1", "Totem[0]"), ("totem2", "Totem[1]"),
] + [("reagent%d" % i, "Reagent[%d]" % (i - 1)) for i in range(1, 9)] + [
    ("reagentCount%d" % i, "ReagentCount[%d]" % (i - 1)) for i in range(1, 9)] + [
    ("equippedItemClass", "EquippedItemClass"),
    ("equippedItemSubClassMask", "EquippedItemSubclass"),
    ("equippedItemInventoryTypeMask", "EquippedItemInvTypes"),
] + [("effectMechanic%d" % i, "EffectMechanic[%d]" % (i - 1)) for i in range(1, 4)] + [
    ("spellVisual1", "SpellVisualID[0]"), ("spellVisual2", "SpellVisualID[1]"),
    ("activeIconId", "ActiveIconID"), ("spellPriority", "SpellPriority"),
    ("name", "Name_lang_enUS"), ("nameSubtext", "NameSubtext_lang_enUS"),
    ("description", "Description_lang_enUS"),
    ("auraDescription", "AuraDescription_lang_enUS"),
    ("maxTargetLevel", "MaxTargetLevel"), ("spellFamilyName", "SpellClassSet"),
    ("maxAffectedTargets", "MaxTargets"), ("dmgClass", "DefenseType"),
    ("preventionType", "PreventionType"), ("stanceBarOrder", "StanceBarOrder"),
] + [("dmgMultiplier%d" % i, "EffectChainAmplitude[%d]" % (i - 1)) for i in range(1, 4)] + [
    ("minFactionId", "MinFactionID"), ("minReputation", "MinReputation"),
    ("requiredAuraVision", "RequiredAuraVision"),
]


def spell_columns(root: Path) -> set:
    """Column names of the Spell binding, arrays and locstrings expanded."""
    sys.path.insert(0, str(root))
    from clientpatch.binding import load_binding  # noqa: E402
    binding = load_binding(root / "bindings" / "1.12.1.5875" / "Spell.toml")
    return {col.name for col in binding.columns}


def pairs(root: Path) -> list:
    rules = tomllib.loads((root / "consistency" / "server.toml").read_text(encoding="utf-8"))
    rule = next(r for r in rules["rule"] if r["id"] == "spell-matches-server")
    result = [(p["sql"], p["dbc"]) for p in rule["pair"]] + EXTRA_PAIRS
    seen_sql, seen_dbc = set(), set()
    for sql, dbc in result:
        if sql in seen_sql or dbc in seen_dbc:
            raise SystemExit("duplicate pair for %s / %s" % (sql, dbc))
        seen_sql.add(sql)
        seen_dbc.add(dbc)
    return result


def generate(spells_csv: str, root: Path = ROOT) -> str:
    mapping = pairs(root)
    columns = spell_columns(root)
    missing = [dbc for _, dbc in mapping if dbc not in columns]
    if missing:
        raise SystemExit("pairs name columns the Spell binding lacks: %s" % ", ".join(missing))

    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(["op", "key", "field", "value", "note"])
    rows = list(csv.DictReader(io.StringIO(spells_csv)))
    if not rows:
        raise SystemExit("no spells given")
    ids = [int(r["id"]) for r in rows]
    if len(ids) != len(set(ids)):
        raise SystemExit("duplicate spell id in the input")
    for r in rows:
        spell, note = int(r["id"]), r.get("note", "").strip()
        writer.writerow(["insert", spell, "", "copy:%d" % int(r["copy_from"]), note])
        for sql, dbc in mapping:
            writer.writerow(["set", spell, dbc, "sql:spell_template.%s" % sql, ""])
        mask = r["class_mask"].strip()
        if mask != "copy":
            value = int(mask, 0)
            if not 0 <= value < 1 << 64:
                raise SystemExit("class_mask of %d is not a 64-bit value" % spell)
            writer.writerow(["set", spell, "SpellClassMask[0]", value & 0xFFFFFFFF, "spellFamilyFlags low"])
            writer.writerow(["set", spell, "SpellClassMask[1]", value >> 32, "spellFamilyFlags high"])
    return out.getvalue()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spells", required=True, help="CSV: id,copy_from,class_mask,note")
    ap.add_argument("--out", required=True, help="delta file to write")
    ap.add_argument("--header", default="", help="comment lines to put first (# is added)")
    args = ap.parse_args()
    text = generate(Path(args.spells).read_text(encoding="utf-8"))
    head = "".join("# %s\n" % line for line in args.header.splitlines())
    lines = text.splitlines(keepends=True)
    Path(args.out).write_text(lines[0] + head + "".join(lines[1:]), encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
