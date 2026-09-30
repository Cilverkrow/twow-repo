#!/usr/bin/env python3
"""Renumber our own spell and enchantment IDs in the clientpatch inputs (#455).

The 1.12 protocol sends spell IDs as uint16 in SMSG_INITIAL_SPELLS,
SMSG_SUPERCEDED_SPELL and SMSG_REMOVED_SPELL (twow-core Player.cpp), so a
spell >= 65536 reaches the client as id - 65536 after a relog. Train 8b moves
every custom spell into 61002-61220 (map by OB-10, checked by OB-50) and the
four enchantments 90141-90144 behind the Turtle range (3060-3063).

The rewrite is field-aware, never a blind search-and-replace: an enchantment
ID and a spell ID can carry the same number (90141 is both).

  * Spell deltas: the row key (spell map); values are sql:spell_template.*
    and follow the server migration.
  * Talent deltas: SpellRank[0..8] and RequiredSpellID values (spell map).
  * SpellItemEnchantment deltas: the row key (enchant map), EffectArg[0..2]
    values (spell map).
  * Spell inputs (tools/inputs/*-spells.csv): the id column.
  * Talent inputs (tools/inputs/*-talents.csv): SpellRank_0..8, RequiredSpellID.
  * Comment lines of the Spell and Talent deltas: numbers of the spell map.

Standard library only. Idempotent: running it twice changes nothing more,
because no new ID is an old one.

    python3 tools/renumber_ids.py --spells tools/inputs/455-spell-renumber-8b.csv \
        --enchants tools/inputs/455-enchant-renumber-8b.csv [--check]
"""

import argparse
import csv
import io
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOKEN = re.compile(r"(?<![0-9])(9[0-9]{4})(?![0-9])")
SPELL_FIELD = re.compile(r"^(SpellRank\[[0-8]\]|RequiredSpellID|EffectArg\[[0-2]\])$")
INPUT_SPELL_COLS = re.compile(r"^(id|SpellRank_[0-8]|RequiredSpellID)$")


def load_map(path: Path) -> dict[int, int]:
    m = {}
    for r in csv.DictReader(path.read_text(encoding="utf-8").splitlines()):
        old, new = int(r["old_id"]), int(r["new_id"])
        if old in m or new in m.values():
            raise SystemExit(f"{path}: duplicate mapping for {old} or {new}")
        m[old] = new
    if set(m) & set(m.values()):
        raise SystemExit(f"{path}: an old ID is also a new ID")
    return m


def _csv_line(fields: list[str]) -> str:
    buf = io.StringIO()
    csv.writer(buf, lineterminator="").writerow(fields)
    return buf.getvalue()


def _map_value(value: str, m: dict[int, int]) -> str:
    return str(m.get(int(value), int(value))) if value.strip().isdigit() else value


def rewrite_delta(text: str, key_map: dict[int, int], spells: dict[int, int]) -> str:
    out = []
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        eol = line[len(body):]
        if body.startswith("#"):
            out.append(TOKEN.sub(lambda t: str(spells.get(int(t.group(1)), int(t.group(1)))), body) + eol)
            continue
        if not body or body.startswith("op,"):
            out.append(line)
            continue
        f = next(csv.reader([body]))
        f[1] = _map_value(f[1], key_map)
        if len(f) > 3 and SPELL_FIELD.match(f[2]):
            f[3] = _map_value(f[3], spells)
        out.append(_csv_line(f) + eol)
    return "".join(out)


def rewrite_input(text: str, spells: dict[int, int]) -> str:
    lines = text.splitlines(keepends=True)
    header = next(csv.reader([lines[0]]))
    cols = [i for i, h in enumerate(header) if INPUT_SPELL_COLS.match(h)]
    out = [lines[0]]
    for line in lines[1:]:
        body = line.rstrip("\r\n")
        eol = line[len(body):]
        f = next(csv.reader([body]))
        for i in cols:
            f[i] = _map_value(f[i], spells)
        out.append(_csv_line(f) + eol)
    return "".join(out)


def plan(spells: dict[int, int], enchants: dict[int, int]) -> dict[Path, str]:
    changed = {}
    ch = ROOT / "changes"
    jobs = [(p, spells) for p in sorted((ch / "Spell").glob("*.csv"))]
    jobs += [(p, {}) for p in sorted((ch / "Talent").glob("*.csv"))]
    jobs += [(p, enchants) for p in sorted((ch / "SpellItemEnchantment").glob("*.csv"))]
    for path, key_map in jobs:
        old = path.read_text(encoding="utf-8")
        new = rewrite_delta(old, key_map, spells)
        if new != old:
            changed[path] = new
    for path in sorted((ROOT / "tools" / "inputs").glob("*-spells.csv")) + \
            sorted((ROOT / "tools" / "inputs").glob("*-talents.csv")):
        old = path.read_text(encoding="utf-8")
        new = rewrite_input(old, spells)
        if new != old:
            changed[path] = new
    return changed


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--spells", type=Path, required=True)
    ap.add_argument("--enchants", type=Path, required=True)
    ap.add_argument("--check", action="store_true", help="only report files that would change")
    a = ap.parse_args(argv)
    changed = plan(load_map(a.spells), load_map(a.enchants))
    for path in changed:
        print(("would change " if a.check else "changed ") + str(path.relative_to(ROOT)))
        if not a.check:
            path.write_bytes(changed[path].encode("utf-8"))
    return 1 if (a.check and changed) else 0


if __name__ == "__main__":
    sys.exit(main())
