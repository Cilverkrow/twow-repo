#!/usr/bin/env python3
"""Write the Spell.dbc delta of the player mount spells (#295, riding in four stages).

The server picks the mounted speed by riding rank and mount family (CV-14).
The client shows the family in two places: the buff text of every player mount
spell, and the aura-32 value of the spells that #295 moves to family 1. Both
values come from the server export (``sql:spell_template.*``), so the delta
only names spells and columns. The input is a CSV, one line per delta row:

    id,section,family,name
    16082,points,1,Palomino Stallion
    16082,text,1,Palomino Stallion

- ``section``: ``points`` - the aura-32 value of effect 2
  (``EffectBasePoints[1]``; +100 -> +60 for the riding-75 mounts whose spell
  gave +100); ``text`` - the buff text (``AuraDescription_lang_enUS``) that
  names the speeds of the family.
- ``family``: ``1`` (own aura-32 value below 100: +60/+100 %), ``2`` (100 and
  above: +60/+100/+140/+180 %) or ``2-speed100`` (mount-speed-100 flag: at
  least +100 %). A ``points`` spell is family 1 and has a ``text`` line too.
- ``name``: the spell name for the note, as in spell_template (blanks kept,
  e.g. 33407 "Sandy Riding Crab "), in ASCII (U+2019 written as ').

The delta is sorted by section, then spell ID, and carries its own header, so
--out reproduces the committed file byte for byte and --check finds a hand
edit or a stale input list. With --core it compares the input with the W2b
migration of a twow-core checkout (read-only, no database): the same spell IDs
as its IN lists, the same aura-32 spells, every spell in the text update of
its family. Standard library only.

    python3 tools/gen_mount_spells.py --spells tools/inputs/295-mount-spells.csv \\
        --out changes/Spell/0295_mount_spells.csv
    python3 tools/gen_mount_spells.py --spells tools/inputs/295-mount-spells.csv \\
        --check changes/Spell/0295_mount_spells.csv --core <twow-core checkout>
"""
import argparse
import csv
import io
import re
import sys
from pathlib import Path

# The W2b migration of #295 (mount spells in spell_template), relative to a twow-core checkout.
MIGRATION = "sql/database_updates/20261002212000_world.sql"

FIELDS = ["id", "section", "family", "name"]
# section -> (Spell binding column, spell_template column)
SECTIONS = {
    "points": ("EffectBasePoints[1]", "effectBasePoints2"),
    "text": ("AuraDescription_lang_enUS", "auraDescription"),
}
# (section, family) -> note; no other combination is valid input.
NOTES = {
    ("points", "1"): "family 1, aura-32 value 100 -> 60",
    ("text", "1"): "family 1",
    ("text", "2"): "family 2",
    ("text", "2-speed100"): "family 2, speed-100 flag",
}
# The buff text of each family, as the migration writes it.
FAMILY_TEXTS = {
    "Speed scales with your Riding skill: +60% (75), +100% (150 and higher).": "1",
    "Speed scales with your Riding skill: +60% (75), +100% (150), +140% (225), +180% (300).": "2",
    "Speed scales with your Riding skill: +100% (up to 150), +140% (225), +180% (300).": "2-speed100",
}
HEADER = """\
# #295 train 9, player mount spells (twow-core 20261002212000, W2b). Values from spell_template,
# the server is the source of truth; the server picks the mounted speed (CV-14).
# 1. The {points} mount spells of the riding-75 items whose spell gave +100 % (Goblin and High Elf
#    racial mounts among them) become family 1: aura-32 value 100 -> 60 (EffectBasePoints[1] 99 -> 59).
# 2. The buff text of every player mount spell names the speeds of its family: family 1 (own
#    aura-32 value below 100) +60/+100 %, family 2 (100 and above) +60/+100/+140/+180 %,
#    mount-speed-100 flag at least +100 %. Same {texts} spells as the migration's list.
# Generated (aura-32 rows, then buff-text rows, each by spell ID): tools/gen_mount_spells.py from tools/inputs/295-mount-spells.csv;
# edit the input list, never this file (tests/test_gen_mount_spells.py compares the two).
"""

IN_LIST = re.compile(r"`entry` IN \(([0-9,\s]*)\)")
NEW_TEXT = re.compile(r"'(Speed scales with your Riding skill: [^']*)'")
SET_POINTS = re.compile(r"SET\s+`effectBasePoints2`\s*=\s*59\b")


def load(spells_csv: str) -> list:
    """The input rows, checked, sorted by section, then spell ID."""
    reader = csv.DictReader(io.StringIO(spells_csv))
    if reader.fieldnames != FIELDS:
        raise SystemExit("the header must be %s" % ",".join(FIELDS))
    rows, seen, names, text_family = [], set(), {}, {}
    for line, r in enumerate(reader, start=2):
        if None in r or None in r.values():
            raise SystemExit("line %d: %d fields expected" % (line, len(FIELDS)))
        try:
            spell = int(r["id"])
        except ValueError:
            raise SystemExit("line %d: id %r is not a number" % (line, r["id"])) from None
        section, family, name = r["section"], r["family"], r["name"]
        if not 0 < spell < 1 << 16:
            raise SystemExit("line %d: %d is not a 16-bit spell ID" % (line, spell))
        if (section, family) not in NOTES:
            raise SystemExit("line %d: spell %d: section %r with family %r is not valid"
                             % (line, spell, section, family))
        if not name.strip() or not name.isascii():
            raise SystemExit("line %d: spell %d needs an ASCII name" % (line, spell))
        if (spell, section) in seen:
            raise SystemExit("line %d: spell %d twice in section %s" % (line, spell, section))
        if names.setdefault(spell, name) != name:
            raise SystemExit("line %d: spell %d is called %r on another line" % (line, spell, names[spell]))
        seen.add((spell, section))
        if section == "text":
            text_family[spell] = family
        rows.append({"id": spell, "section": section, "family": family, "name": name})
    if not rows:
        raise SystemExit("no mount spells given")
    for spell, section in sorted(seen):
        # 100 -> 60 makes the spell family 1, so its buff text must be the family-1 text.
        if section == "points" and text_family.get(spell) != "1":
            raise SystemExit("spell %d: a points line needs a family-1 text line" % spell)
    order = list(SECTIONS)
    return sorted(rows, key=lambda r: (order.index(r["section"]), r["id"]))


def render(rows: list) -> str:
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(["op", "key", "field", "value", "note"])
    out.write(HEADER.format(points=sum(r["section"] == "points" for r in rows),
                            texts=sum(r["section"] == "text" for r in rows)))
    for r in rows:
        dbc, sql = SECTIONS[r["section"]]
        note = "%s: %s (CV-14)" % (r["name"], NOTES[r["section"], r["family"]])
        writer.writerow(["set", r["id"], dbc, "sql:spell_template.%s" % sql, note])
    return out.getvalue()


def generate(spells_csv: str) -> str:
    return render(load(spells_csv))


def migration_lists(sql_text: str) -> tuple:
    """(every spell of an IN list, the aura-32 spells, {spell: text family}) of the W2b migration."""
    code = "\n".join(ln for ln in sql_text.splitlines() if not ln.lstrip().startswith("--"))
    every, points, families = set(), set(), {}
    for statement in code.split(";"):
        ids = {int(v) for block in IN_LIST.findall(statement) for v in re.findall(r"\d+", block)}
        every |= ids
        if not statement.lstrip().startswith("UPDATE `spell_template`"):
            continue
        if SET_POINTS.search(statement):
            points |= ids
            continue
        texts = set(NEW_TEXT.findall(statement))
        if len(texts) != 1 or not texts <= set(FAMILY_TEXTS):
            raise ValueError("%s: an UPDATE without exactly one known mount text: %s"
                             % (MIGRATION, " ".join(statement.split())[:160]))
        family = FAMILY_TEXTS[texts.pop()]
        for spell in ids:
            if families.setdefault(spell, family) != family:
                raise ValueError("%s: spell %d is in the text updates of two families" % (MIGRATION, spell))
    return every, points, families


def check_core(rows: list, core: str) -> list:
    """Differences between the input and the W2b migration of a twow-core checkout."""
    path = Path(core) / MIGRATION
    if not path.is_file():
        raise FileNotFoundError("%s has no %s (not a twow-core checkout with #295)" % (core, MIGRATION))
    every, points, families = migration_lists(path.read_text(encoding="utf-8"))
    ours = {r["id"] for r in rows}
    our_points = {r["id"] for r in rows if r["section"] == "points"}
    our_families = {r["id"]: r["family"] for r in rows if r["section"] == "text"}
    errors = ["spell %d is in the migration but not in the delta" % s for s in sorted(every - ours)]
    errors += ["spell %d is in the delta but not in the migration" % s for s in sorted(ours - every)]
    for spell in sorted(ours & every):
        if (spell in points) != (spell in our_points):
            errors.append("spell %d: aura-32 value 100 -> 60 in the %s only"
                          % (spell, "migration" if spell in points else "delta"))
        if families.get(spell) != our_families.get(spell):
            errors.append("spell %d: text family %s in the migration, %s in the delta"
                          % (spell, families.get(spell, "none"), our_families.get(spell, "none")))
    return errors


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spells", required=True, help="CSV: id,section,family,name")
    ap.add_argument("--out", help="write the delta here")
    ap.add_argument("--check", help="fail when this committed delta is not what --spells generates")
    ap.add_argument("--core", help="twow-core checkout whose W2b migration the input must match")
    args = ap.parse_args(argv)
    rows = load(Path(args.spells).read_text(encoding="utf-8"))
    text = render(rows)
    errors = []
    try:
        if args.core:
            errors += check_core(rows, args.core)
        if args.out and not errors:
            Path(args.out).write_text(text, encoding="utf-8", newline="\n")
        if args.check and Path(args.check).read_text(encoding="utf-8") != text:
            errors.append("%s is not what %s generates; run with --out" % (args.check, args.spells))
    except (OSError, ValueError) as error:
        errors.append(str(error))
    for error in errors:
        print("ERROR %s" % error)
    print("MOUNTSPELLS=%s spells=%d points=%d errors=%d core=%s" % (
        "FAIL" if errors else "PASS", len({r["id"] for r in rows}),
        sum(r["section"] == "points" for r in rows), len(errors), "checked" if args.core else "skipped"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
