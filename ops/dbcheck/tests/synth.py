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


# Kill-credit objectives per quest: helper NPCs 400-406 (see the creature rows below).
OBJECTIVES = {10: [400, 401, 402, 405], 11: [403, 404, 406], 12: [407, 408]}


def world() -> sqlite3.Connection:
    con = empty_db()
    # Creatures: 100 boss spawned, 101 boss never spawned, 102 boss without loot,
    # 103 boss summoned by a database script, 104 boss summoned by C++ (named in the
    # expected list), 105 boss spawned only through id2, 200/201 trash, 300 spawned giver
    # (through id3), 301 giver never spawned, 302 turn-in NPC never spawned.
    for entry, name, loot, rank in [
        (100, "Boss Alpha", 100, 3), (101, "Boss Beta", 101, 3), (102, "Boss Gamma", 0, 3), (103, "Boss Delta", 103, 3),
        (104, "Boss Epsilon", 104, 3), (105, "Boss Zeta", 105, 3), (106, "Boss Eta", 0, 3), (200, "Trash Mob", 200, 0), (201, "Trash Two", 201, 0),
        (300, "Giver", 0, 0), (301, "Ghost Giver", 0, 0), (302, "Ghost Ender", 0, 0),
        (400, "quest_10_no_source", 0, 0), (401, "quest_10_spawned", 0, 0), (402, "quest_10_script_credit", 0, 0),
        (403, "quest_10_ai_credit", 0, 0), (404, "quest_10_eventai", 0, 0), (405, "Plain Objective", 0, 0),
        (406, "quest_10_summoned", 0, 0),
        (407, "quest_12_cpp", 0, 0), (408, "questlike_12", 0, 0),
    ]:
        insert(con, "creature_template", entry=entry, name=name, loot_id=loot, rank=rank)
    insert(con, "creature", guid=1, id=100, map=1)
    insert(con, "creature", guid=2, id=200, map=1)
    insert(con, "creature", guid=3, id=0, id3=300, map=1)
    insert(con, "creature", guid=4, id=0, id2=105, map=1)
    insert(con, "creature", guid=5, id=106, map=9)  # spawned, but not on the instance map
    insert(con, "creature", guid=6, id=401, map=1)
    # Loot. 100: direct rows, a reference group 5 that itself points at group 6, and one unnamed extra.
    # 200: trash drops an item Alpha should have; 201: trash drops one only through a reference group.
    for loot, item, ref in [
        (100, 1001, 1), (100, 1002, 1), (100, 1008, 1), (100, 0, -5), (101, 1001, 1), (200, 1004, 1), (201, 0, -7),
        (103, 1001, 1), (104, 1001, 1), (105, 1001, 1),
    ]:
        insert(con, "creature_loot_template", entry=loot, item=item, mincountOrRef=ref)
    for entry, item, ref in [(5, 1003, 1), (5, 0, -6), (6, 1009, 1), (7, 1010, 1)]:
        insert(con, "reference_loot_template", entry=entry, item=item, mincountOrRef=ref)
    items = [
        (1001, "Sword of Tests", 4), (1002, "Helm of O'Brien", 4), (1003, "Ring via Ref", 4), (1004, "Cloak Elsewhere", 4),
        (1005, "Call of the Wild", 4), (1006, "Orphan Epic", 4), (1007, "Sold Epic", 4), (1008, "Unnamed Extra", 3),
        (1009, "Nested Ring", 4), (1010, "Hidden Ref Item", 4), (1011, "Template Vendor Epic", 4), (1012, "Mailed Epic", 4),
        (1013, "Quest Start Epic", 4), (1014, "Skinned Epic", 4),
    ]
    for entry, name, q in items:
        insert(con, "item_template", entry=entry, name=name, quality=q, start_quest=0)
    insert(con, "npc_vendor", item=1007)
    insert(con, "npc_vendor_template", item=1011)
    insert(con, "mail_loot_template", item=1012)
    insert(con, "skinning_loot_template", item=1014)
    # Quests. Method 2 is the normal case, 0 means "started by a script".
    quests = [
        (10, "Quest Ten", 2, 0, 14, 16), (11, "Quest Eleven", 2, 0, 0, 0), (12, "Quest Twelve", 2, 0, 0, 0),
        (13, "Quest Thirteen", 2, 999, 998, 997), (14, "Quest Fourteen", 2, -10, 0, 0),
        (15, "[DEPRECATED] Retired", 2, 0, 0, 0), (16, "Chain Follower", 2, 0, 0, 0), (17, "Scripted Start", 2, 0, 0, 0),
        (18, "Scripted End", 2, 0, 0, 0), (19, "Method Zero", 0, 0, 0, 0), (20, "Dummy Quest", 2, 0, 0, 0),
        (21, "Old Quest [Deprecated]", 2, 0, 0, 0), (22, "Vanilla Corpse", 2, 0, 0, 0),
    ]
    for entry, title, method, prev, nxt, chain in quests:
        insert(con, "quest_template", entry=entry, Title=title, Method=method, PrevQuestId=prev, NextQuestId=nxt,
               NextQuestInChain=chain, RewItemId1=1003 if entry == 14 else 0, SrcItemId=1013 if entry == 10 else 0,
               **{f"ReqCreatureOrGOId{i + 1}": v for i, v in enumerate(OBJECTIVES.get(entry, []))})
    for quest, giver, ender in [(10, 300, 300), (12, 300, None), (13, 300, 300), (14, 300, 300)]:
        insert(con, "creature_questrelation", id=giver, quest=quest)
        if ender is not None:
            insert(con, "creature_involvedrelation", id=ender, quest=quest)
    insert(con, "creature_involvedrelation", id=300, quest=11)
    for quest in (16, 17):
        insert(con, "creature_involvedrelation", id=300, quest=quest)  # 16: no starter; 17: a script starts it
    insert(con, "creature_questrelation", id=300, quest=18)  # 18: a script turns it in
    insert(con, "creature_questrelation", id=301, quest=10)  # a giver that is never spawned
    insert(con, "creature_involvedrelation", id=302, quest=14)  # a turn-in NPC that is never spawned
    # A database script summons boss 103 (command 10, datalong = entry).
    insert(con, "generic_scripts", command=10, datalong=103)
    insert(con, "generic_scripts", command=8, datalong=402)  # kill credit for helper 402
    insert(con, "creature_ai_scripts", command=8, datalong=403)  # EventAI action grants credit for 403
    insert(con, "creature_ai_events", creature_id=404)
    insert(con, "gossip_scripts", command=10, datalong=406)  # a script summons helper 406
    con.commit()
    return con
