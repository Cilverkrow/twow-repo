"""Synthetic fixture: a tiny world database built from the committed binding.

No real game data. Names and ids are invented so the tests can state exactly
which finding each row must produce.
"""

import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from dbcheck.binding import load_binding  # noqa: E402
from dbcheck.rules import load_rules  # noqa: E402

BINDING = load_binding(ROOT / "bindings" / "tw-world.toml")
RULES, MACROS = load_rules(ROOT / "rules")


def empty_db() -> sqlite3.Connection:
    """Every bound table with every bound column, all empty."""
    con = sqlite3.connect(":memory:")
    cols: dict[str, list[str]] = {}
    for t in BINDING.tables.values():
        cols.setdefault(t.physical, [])
        for c in t.columns.values():
            if c not in cols[t.physical]:
                cols[t.physical].append(c)
    for table, cs in cols.items():
        con.execute(f'CREATE TABLE "{table}" (' + ", ".join(f'"{c}"' for c in cs) + ")")
    con.commit()
    return con


def insert(con, table, **row):
    keys = list(row)
    con.execute(
        f'INSERT INTO "{table}" (' + ",".join(f'"{k}"' for k in keys) + ") VALUES (" + ",".join("?" * len(keys)) + ")",
        [row[k] for k in keys],
    )


def world() -> sqlite3.Connection:
    con = empty_db()
    # Bosses: 100 spawned, 101 never spawned, 102 is a boss-rank NPC without loot.
    for entry, name, loot, rank in [(100, "Boss Alpha", 100, 3), (101, "Boss Beta", 101, 3), (102, "Boss Gamma", 0, 3),
                                    (200, "Trash Mob", 200, 0)]:
        insert(con, "creature_template", entry=entry, name=name, loot_id=loot, rank=rank)
    insert(con, "creature", guid=1, id=100, map=1)
    insert(con, "creature", guid=2, id=200, map=1)
    # Loot: 100 = two direct rows + one reference group + one unnamed extra; 200 = trash drops an item Alpha should have.
    for loot, item, ref in [(100, 1001, 1), (100, 1002, 1), (100, 1008, 1), (100, 0, -5), (101, 1001, 1), (200, 1004, 1)]:
        insert(con, "creature_loot_template", entry=loot, item=item, mincountOrRef=ref)
    insert(con, "reference_loot_template", entry=5, item=1003)
    items = [
        (1001, "Sword of Tests", 4), (1002, "Helm of O'Brien", 4), (1003, "Ring via Ref", 4), (1004, "Cloak Elsewhere", 4),
        (1005, "Call of the Wild", 4), (1006, "Orphan Epic", 4), (1007, "Sold Epic", 4), (1008, "Unnamed Extra", 3),
    ]
    for entry, name, q in items:
        insert(con, "item_template", entry=entry, name=name, quality=q, start_quest=0)
    insert(con, "npc_vendor", item=1007)
    # Quests: 10 fine, 11 no starter, 12 no ender, 13 broken chain, 14 fine (negative prev = must be active).
    for entry, title, prev, nxt, chain in [(10, "Quest Ten", 0, 14, 0), (11, "Quest Eleven", 0, 0, 0), (12, "Quest Twelve", 0, 0, 0),
                                            (13, "Quest Thirteen", 999, 998, 997), (14, "Quest Fourteen", -10, 0, 0),
                                            (15, "[DEPRECATED] Retired", 0, 0, 0)]:
        insert(con, "quest_template", entry=entry, Title=title, PrevQuestId=prev, NextQuestId=nxt, NextQuestInChain=chain,
               RewItemId1=1003 if entry == 14 else 0)
    for quest, giver, ender in [(10, 300, 300), (12, 300, None), (13, 300, 300), (14, 300, 300)]:
        insert(con, "creature_questrelation", id=giver, quest=quest)
        if ender is not None:
            insert(con, "creature_involvedrelation", id=ender, quest=quest)
    insert(con, "creature_involvedrelation", id=300, quest=11)
    con.commit()
    return con
