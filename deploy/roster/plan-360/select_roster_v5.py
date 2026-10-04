#!/usr/bin/env python3
"""Race-balanced roster expansion for any size (twow-repo#366, owner requirement 2026-09-27).

Planning data only; touches no database. The rows of the current roster plan (--base) keep
their ordinals; new rows are appended (EXPAND). With --replace-excess, bots of a race above
its even share are swapped at their ordinal (REPLACE); the replaced characters stay untouched.
Plan v3 (owner decisions 2026-09-27): wave 1 = 180 (10/20/60 per faction), wave 2 = 360
(20/40/120 per faction).

1. Slots, without any pool. Per faction:
   - races fill up to the even share (faction size / 5); nobody shrinks unless
     --replace-excess swaps the excess (fullest race x class x role first, then lowest
     --levels, then highest ordinal; the replacement keeps the role);
   - tanks / healers / DPS end at --per-faction (hard);
   - every tank class fills up to an equal share of the tanks (owner: bear, warrior, paladin,
     rogue tank, shaman tank, 20 % each); classes above their share keep their tanks unless
     --respec-tanks respecs the surplus to a DPS path of their class (wave 2, level kept);
   - no race x class x role above --cap, except cells the unchanged base already has above;
   - every slot keeps all of this reachable (max-flow check race -> class/role cell -> role,
     tanks through a per-class node);
   - otherwise each slot takes, in this order: the role furthest behind its target; the race
     with the smallest share of that role relative to its room for it (cap x classes that can
     play the role), so races with several healer classes carry the healers; the race furthest
     behind its size; the emptiest class cell; the rarest talent path; the rarest gender.
     Only pairs of --catalog (filtered by --catalog-sources) and paths of --specs are used.
   `--summary-out` writes the result per race and the group capacity (dungeon, raid 20/40).
   `--demand` writes the candidate demand per race x class x gender; against a pool snapshot
   it gives the number of bots the factory must create (FACTORY column).
2. Fill (--pool): every slot takes the free pool character of its race and class, same
   gender first, lowest (level, guid). Names (--names-out), the REPLACE list (--replace-out)
   and CHANGED_ORDINALS (for reset-l1 --ordinals) are written.

    python3 select_roster_v5.py --base ../plan-154/v4-154-roster-plan.csv --catalog race-class-catalog.tsv \
        --specs spec-roles.tsv --target 180 --per-faction 10,20,60 --cap 4 --replace-excess \
        --levels levels.tsv --demand demand.tsv [--pool free-pool.tsv --taken-names names.txt \
        --out v5-180-roster-plan.csv --names-out new-names.tsv --replace-out replace.tsv]
"""
import argparse
import csv
import hashlib
import itertools
import math
import sys
from collections import Counter

ALLIANCE = (1, 3, 4, 7, 10)
HORDE = (2, 5, 6, 8, 9)
ROLES = ("TANK", "HEALER", "DPS")
DRUID = 11

# Owner profession shares (plan-154/README.md): pair -> (percent, classes preferred first).
PROFESSIONS = [
    ("Herbalism/Alchemy", 20, [5, 2, 11, 7]),
    ("Tailoring/Enchanting", 18, [8, 5, 9]),
    ("Skinning/Leatherworking", 18, [11, 7, 3, 4]),
    ("Mining/Blacksmithing", 12, [1, 2]),
    ("Mining/Engineering", 10, [8, 9, 4]),
    ("Mining/Jewelcrafting", 8, [2, 5]),
    ("Herbalism/Mining", 14, []),
]


def faction(race):
    return "A" if race in ALLIANCE else "H"


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest().upper()


def read_tsv(path):
    with open(path, newline="", encoding="utf-8") as f:
        return [r for r in csv.reader(f, delimiter="\t") if r and not r[0].startswith("#")]


def fail(msg):
    raise SystemExit(f"ERROR: {msg}")


def largest_remainder(total, weights):
    raw = [total * w / sum(weights) for w in weights]
    out = [int(x) for x in raw]
    for i in sorted(range(len(raw)), key=lambda i: (-(raw[i] - out[i]), i))[:total - sum(out)]:
        out[i] += 1
    return out


def water_fill(have, extra, keys):
    """Targets after adding `extra` one by one to the key with the fewest (ties: key order).

    Keys already above the even share keep their count; nobody shrinks (no REPLACE)."""
    target = {k: have.get(k, 0) for k in keys}
    for _ in range(extra):
        k = min(keys, key=lambda k: (target[k], keys.index(k)))
        target[k] += 1
    return target


def capped_fill(have, extra, keys, caps):
    """water_fill, but no key goes above caps[key] (or its current count, if already higher);
    what a capped key cannot take goes to the others (#518: e.g. fewer Horde paladin tanks)."""
    fixed = {}
    while True:
        free = [k for k in keys if k not in fixed]
        rest = extra - sum(fixed[k] - have.get(k, 0) for k in fixed)
        target = water_fill(have, rest, free)
        over = [k for k in free if caps.get(k) is not None and target[k] > max(caps[k], have.get(k, 0))]
        if not over or len(over) == len(free):
            target.update(fixed)
            return target
        for k in over:
            fixed[k] = max(caps[k], have.get(k, 0))


def max_flow_ok(race_rem, role_rem, cell_free, tank_class_rem):
    """Can the remaining race counts be spread over cells (free capacity) onto the roles,
    with the tanks split by class as tank_class_rem says?"""
    total = sum(race_rem.values())
    if total != sum(role_rem.values()):
        return False
    # nodes: "s", ("r", race), ("c", race, cls, role), ("q", cls) for tanks, ("o", role), "t"
    cap = {}

    def edge(u, v, c):
        cap[(u, v)] = cap.get((u, v), 0) + c
        cap.setdefault((v, u), 0)
    for race, n in race_rem.items():
        edge("s", ("r", race), n)
    for (race, cls, role), free in cell_free.items():
        if race in race_rem and free > 0:
            edge(("r", race), ("c", race, cls, role), free)
            edge(("c", race, cls, role), ("q", cls) if role == "TANK" else ("o", role), free)
    for cls, n in tank_class_rem.items():
        edge(("q", cls), ("o", "TANK"), n)
    for role, n in role_rem.items():
        edge(("o", role), "t", n)
    adj = {}
    for u, v in cap:
        adj.setdefault(u, []).append(v)
    flow = 0
    while True:
        prev, stack = {"s": None}, ["s"]
        while stack and "t" not in prev:
            u = stack.pop()
            for v in adj.get(u, []):
                if v not in prev and cap[(u, v)] > 0:
                    prev[v] = u
                    stack.append(v)
        if "t" not in prev:
            return flow == total
        path, v = [], "t"
        while prev[v] is not None:
            path.append((prev[v], v))
            v = prev[v]
        push = min(cap[e] for e in path)
        for u, v in path:
            cap[(u, v)] -= push
            cap[(v, u)] += push
        flow += push


def plan_slots(base, catalog, known, specs, target, per_faction, cell_cap, replace_excess=False, levels=None,
               respec_tanks=False, respecs=None, healer_min=0, class_role_max=None, female_share=None):
    """Return the new slots: dicts race, cls, gender, path, role; a slot with "replace" takes
    over that base ordinal (REPLACE), the others are appended in order (EXPAND).

    #518 options: healer_min = at least that many healers of every healer class of the faction
    (one per guild); class_role_max = {(faction, class, role): n} hard limit per faction (e.g.
    Horde paladins = undead only); female_share = target share of women per faction."""
    class_role_max = class_role_max or {}
    if target % 2:
        fail("target must be even (50/50 factions)")
    half = target // 2
    if sum(per_faction) != half:
        fail(f"--per-faction {per_faction} does not add up to {half}")
    role_target = dict(zip(ROLES, per_faction))
    paths = {}  # (class, role) -> [path]
    for cls, path, role in specs:
        paths.setdefault((cls, role), []).append(path)
    roster = [dict(race=int(r["race"]), cls=int(r["class"]), gender=int(r["gender"]),
                   path=r["talent_path"], role=r["role"], ordinal=int(r["ordinal"]), guid=int(r["guid"]))
              for r in base]
    for b in roster:
        if (b["race"], b["cls"]) not in known:
            fail(f"base row race {b['race']} class {b['cls']} is not a known pair")
    levels = levels or {}
    respecs = respecs if respecs is not None else []
    per_faction_slots = {}
    for fa, races in (("A", ALLIANCE), ("H", HORDE)):
        mine = [b for b in roster if faction(b["race"]) == fa]
        if len(mine) > half:
            fail(f"faction {fa} already has {len(mine)} bots, more than {half}")
        replaced = []
        if replace_excess:
            # owner: swap bots of a race above its even share (REPLACE); the replaced bots stay
            # untouched and offline. Take them from the fullest race x class x role cell first,
            # then the lowest level (least progress lost), then the highest ordinal.
            have = Counter(b["race"] for b in mine)
            low, extra = divmod(half, len(races))
            order = sorted(races, key=lambda r: (-have[r], r))
            even = {r: low + (1 if i < extra else 0) for i, r in enumerate(order)}
            for race in races:
                excess = have[race] - even[race]
                if excess <= 0:
                    continue
                cells = Counter((b["cls"], b["role"]) for b in mine if b["race"] == race)
                pick = sorted((b for b in mine if b["race"] == race),
                              key=lambda b: (-cells[(b["cls"], b["role"])], levels.get(b["guid"], 0), -b["ordinal"]))
                replaced += pick[:excess]
            mine = [b for b in mine if b not in replaced]
        race_target = water_fill(Counter(b["race"] for b in mine), half - len(mine), list(races))
        race_rem = {r: race_target[r] - sum(1 for b in mine if b["race"] == r) for r in races}
        usable = {(race, cls, role) for race, cls in catalog if race in races for role in ROLES
                  if paths.get((cls, role))}
        # owner: every tank class takes an equal share of the tanks (bear, warrior, paladin, ...)
        tank_classes = sorted({cls for _, cls, role in usable if role == "TANK"})
        if respec_tanks:
            # owner (wave 2): tanks of a class above its share are respecced to a DPS path of
            # their class (level kept; A6 sets the talent reset). Taken from the race with the
            # most tanks of that class first, then the highest ordinal.
            share = water_fill({}, role_target["TANK"], tank_classes)
            for cls in tank_classes:
                have = [b for b in mine if b["role"] == "TANK" and b["cls"] == cls]
                excess = len(have) - share[cls]
                if excess <= 0:
                    continue
                per_race = Counter(b["race"] for b in have)
                for b in sorted(have, key=lambda b: (-per_race[b["race"]], -b["ordinal"]))[:excess]:
                    in_race = Counter(x["path"] for x in mine if x["race"] == b["race"] and x["cls"] == cls)
                    new_path = min(paths[(cls, "DPS")], key=lambda p: (in_race[p], p))
                    respecs.append(dict(ordinal=b["ordinal"], guid=b["guid"], old_path=b["path"],
                                        path=new_path, role="DPS"))
                    per_race[b["race"]] -= 1
                    b["path"], b["role"] = new_path, "DPS"
        have_role = Counter(b["role"] for b in mine)
        role_rem = {r: role_target[r] - have_role[r] for r in ROLES}
        for r, n in role_rem.items():
            if n < 0:
                fail(f"faction {fa} already has {have_role[r]} {r}, above {role_target[r]}")
        have_tank = Counter(b["cls"] for b in mine if b["role"] == "TANK")
        tank_target = capped_fill(have_tank, role_rem["TANK"], tank_classes,
                                  {c: class_role_max.get((fa, c, "TANK")) for c in tank_classes})
        tank_class_rem = {c: tank_target[c] - have_tank[c] for c in tank_classes}
        cell_count = Counter((b["race"], b["cls"], b["role"]) for b in mine)
        class_role_count = Counter((b["cls"], b["role"]) for b in mine)
        healer_classes = sorted({cls for _, cls, role in usable if role == "HEALER"})
        healer_rem = {c: max(0, healer_min - class_role_count[(c, "HEALER")]) for c in healer_classes}
        if sum(healer_rem.values()) > role_rem["HEALER"]:
            fail(f"faction {fa}: --healer-min {healer_min} x {len(healer_classes)} healer classes "
                 f"does not fit into {role_rem['HEALER']} new healer slots")
        female_target = math.ceil(female_share * half) if female_share is not None else None
        slots = []

        def free():
            return {c: max(0, cell_cap - cell_count[c]) for c in usable}
        if not max_flow_ok(race_rem, role_rem, free(), tank_class_rem):
            fail(f"faction {fa}: races, roles {per_faction}, tank classes and cap {cell_cap} cannot all be met")
        room = {(race, role): sum(cell_cap for c in usable if c[0] == race and c[2] == role) or 1
                for race in races for role in ROLES}
        total_new = {r: max(role_rem[r], 1) for r in ROLES}
        while sum(role_rem.values()):
            for role in sorted(ROLES, key=lambda r: (-role_rem[r] / total_new[r], ROLES.index(r))):
                if role_rem[role] == 0:
                    continue
                options = []
                # #518: healer classes still below --healer-min go first (if any is reachable)
                needy_first = {c for c, n in healer_rem.items() if n > 0} if role == "HEALER" else set()
                for needy in ((needy_first, set()) if needy_first else (set(),)):
                    for race in races:
                        if race_rem[race] == 0:
                            continue
                        for cls in sorted({c for r, c, o in usable if r == race and o == role}):
                            cell = (race, cls, role)
                            if cell_count[cell] >= cell_cap or (role == "TANK" and tank_class_rem[cls] == 0):
                                continue
                            if needy and cls not in needy:
                                continue
                            limit = class_role_max.get((fa, cls, role))
                            if limit is not None and class_role_count[(cls, role)] >= limit:
                                continue
                            race_rem[race] -= 1
                            role_rem[role] -= 1
                            cell_count[cell] += 1
                            if role == "TANK":
                                tank_class_rem[cls] -= 1
                            ok = max_flow_ok(race_rem, role_rem, free(), tank_class_rem)
                            race_rem[race] += 1
                            role_rem[role] += 1
                            cell_count[cell] -= 1
                            if role == "TANK":
                                tank_class_rem[cls] += 1
                            if ok:
                                have = sum(1 for b in mine if b["race"] == race)
                                in_role = sum(1 for b in mine if b["race"] == race and b["role"] == role)
                                in_class = sum(1 for b in mine if b["race"] == race and b["cls"] == cls)
                                # a race with more classes for the role takes a larger share of it
                                options.append(((in_role / room[(race, role)], have / race_target[race], race,
                                                 cell_count[cell], in_class, cls), race, cls))
                    if options:
                        break
                if options:
                    break
            else:
                fail(f"faction {fa}: no feasible slot left")
            _, race, cls = min(options)
            in_race = [b for b in mine if b["race"] == race]
            rcp = Counter((b["cls"], b["path"]) for b in in_race)
            path = min(paths[(cls, role)], key=lambda p: (rcp[(cls, p)], p))
            rg = Counter(b["gender"] for b in in_race if b["cls"] == cls and b["path"] == path)
            g_all = Counter(b["gender"] for b in in_race)
            gender = min((0, 1), key=lambda g: (rg[g], g_all[g], g))
            if female_target is not None:
                # #518 owner: more women than men; women until the faction reaches its share
                women = sum(1 for b in mine if b["gender"] == 1)
                gender = 1 if women < female_target else gender
            s = dict(race=race, cls=cls, gender=gender, path=path, role=role)
            slots.append(s)
            mine.append(s)
            race_rem[race] -= 1
            role_rem[role] -= 1
            cell_count[(race, cls, role)] += 1
            class_role_count[(cls, role)] += 1
            if role == "HEALER" and cls in healer_rem and healer_rem[cls] > 0:
                healer_rem[cls] -= 1
            if role == "TANK":
                tank_class_rem[cls] -= 1
        # each replaced ordinal takes the first planned slot of its role
        for b in sorted(replaced, key=lambda b: b["ordinal"]):
            s = next((s for s in slots if "replace" not in s and s["role"] == b["role"]), None)
            if s is None:
                fail(f"no {b['role']} slot to replace ordinal {b['ordinal']}")
            s.update(replace=b["ordinal"], old_guid=b["guid"])
        per_faction_slots[fa] = slots
    # replacements first (by ordinal), then the appended slots alternating factions
    everything = per_faction_slots["A"] + per_faction_slots["H"]
    out = sorted((s for s in everything if "replace" in s), key=lambda s: s["replace"])
    for a, h in itertools.zip_longest([s for s in per_faction_slots["A"] if "replace" not in s],
                                      [s for s in per_faction_slots["H"] if "replace" not in s]):
        out.extend(s for s in (a, h) if s)
    return out


def assign_professions(base, slots, target):
    have = Counter(r["profession_pair"] for r in base)
    want = largest_remainder(target, [p for _, p, _ in PROFESSIONS])
    need = {label: max(0, w - have[label]) for (label, _, _), w in zip(PROFESSIONS, want)}
    # base rows above a share shrink the others: trim from the end of the list
    surplus = sum(need.values()) - len(slots)
    for label, _, _ in reversed(PROFESSIONS):
        cut = min(surplus, need[label]) if surplus > 0 else 0
        need[label] -= cut
        surplus -= cut
    short = len(slots) - sum(need.values())
    need["Herbalism/Mining"] += short  # can only happen when the base is far below the shares
    for label, _, prefer in PROFESSIONS:
        n = need[label]
        for pass_class in list(prefer) + [None]:
            for s in slots:
                if n == 0:
                    break
                if "pair" in s or (pass_class is not None and s["cls"] != pass_class):
                    continue
                s["pair"] = label
                n -= 1
        if n:
            fail(f"could not place {label}")


# Group templates (tanks, healers, dps) for the capacity table: 5-man dungeon, 20-man raid
# (ZG/AQ20), 40-man raid (MC/BWL/AQ40/Naxx).
GROUPS = [("dungeon 5", (1, 1, 3)), ("raid 20", (2, 5, 13)), ("raid 40", (4, 12, 24))]


def summary(base, slots, cap):
    rows = [(int(r["race"]), int(r["class"]), r["role"]) for r in base]
    rows += [(s["race"], s["cls"], s["role"]) for s in slots]
    lines = []
    for fa, races in (("Alliance", ALLIANCE), ("Horde", HORDE)):
        mine = [r for r in rows if r[0] in races]
        roles = Counter(r[2] for r in mine)
        per_race = Counter(r[0] for r in mine)
        tanks = Counter(r[1] for r in mine if r[2] == "TANK")
        lines += [f"## {fa}: {len(mine)} bots, tanks {roles['TANK']} / healers {roles['HEALER']} / DPS {roles['DPS']}",
                  "", f"Race spread (max - min): {max(per_race.values()) - min(per_race.values())}. "
                  f"Tanks by class: {', '.join(f'class {c}: {n}' for c, n in sorted(tanks.items()))}.",
                  "", "| race | bots | tanks | healers | DPS | largest race x class x role |", "|---|---|---|---|---|---|"]
        for race in races:
            r_rows = [r for r in mine if r[0] == race]
            rr = Counter(r[2] for r in r_rows)
            (cls, role), top = Counter((r[1], r[2]) for r in r_rows).most_common(1)[0]
            lines.append(f"| {race} | {len(r_rows)} | {rr['TANK']} | {rr['HEALER']} | {rr['DPS']} | "
                         f"class {cls} {role}: {top} |")
        lines += ["", "| groups at the same time | template T/H/D | full groups | left over T/H/D |", "|---|---|---|---|"]
        have = (roles["TANK"], roles["HEALER"], roles["DPS"])
        for name, need in GROUPS:
            n = min(h // q for h, q in zip(have, need))
            left = "/".join(str(h - n * q) for h, q in zip(have, need))
            lines.append(f"| {name} | {'/'.join(map(str, need))} | {n} | {left} |")
        lines.append("")
    cells = Counter(rows)
    base_cells = Counter((int(r["race"]), int(r["class"]), r["role"]) for r in base)
    over = sorted(c for c, n in cells.items() if n > cap)
    lines.append(f"Largest race x class x role in the whole roster: {max(cells.values())} (cap {cap}).")
    if over:
        lines.append("Above the cap only from the unchanged base (no REPLACE): "
                     + ", ".join(f"race {r} class {c} {o}: {cells[(r, c, o)]}" for r, c, o in over
                                 if base_cells[(r, c, o)] == cells[(r, c, o)]) + ".")
    return "\n".join(lines) + "\n"


def demand_rows(slots, pool):
    want = Counter((s["race"], s["cls"], s["gender"]) for s in slots)
    free = Counter((c["race"], c["cls"], c["gender"]) for c in pool) if pool is not None else Counter()
    rows = []
    for race, cls in sorted({(r, c) for r, c, _ in want}):
        w0, w1 = want[(race, cls, 0)], want[(race, cls, 1)]
        f0, f1 = free[(race, cls, 0)], free[(race, cls, 1)]
        s0, s1 = max(0, w0 - f0), max(0, w1 - f1)
        # the factory picks the gender at random: ask for twice the larger gap, plus four
        factory = 2 * max(s0, s1) + 4 if s0 or s1 else 0
        rows.append((race, cls, w0, w1, f0, f1, s0, s1, factory))
    return rows


NAME_PARTS = {
    1: (["Rose", "Linden", "Hearth", "Marigold", "Tallow", "Brass", "Ember", "Sparrow", "Thistle", "Briar",
         "Maple", "Candle", "Juniper", "Honey", "Wren", "Oaken", "Lantern", "Ivy", "Tinder", "Barrow", "Lark",
         "Copper", "Meadow", "Willow", "Hazel", "Ashford", "Primrose", "Kettle"],
        ["mantle", "wick", "ford", "helm", "worth", "staff", "moor", "spire", "brook", "field", "gate", "wood"],
        ["veil", "wyn", "lynn", "ra", "belle", "leen", "down", "berry", "mead", "reth", "rine", "ette"]),
    2: (["Gor", "Blood", "Zug", "Skull", "Thrak", "Ash", "Mog", "Rag", "Dur", "Iron", "Kar", "Tusk", "War",
         "Brak", "Vor", "Grom", "Drak", "Nar", "Krag", "Ur"],
        ["rak", "howl", "grin", "maw", "tusk", "gash", "jaw", "nog", "fang", "hul", "gor", "zug"],
        ["aka", "ena", "zha", "ara", "gha", "ana", "ka", "rsha", "ga", "ima"]),
    3: (["Amber", "Braid", "Stone", "Brew", "Rune", "Anvil", "Kettle", "Keg", "Grim", "Thorn", "Moss",
         "Garnet", "Granite", "Copper", "Ale", "Iron", "Coal", "Flint", "Bronze", "Barrel"],
        ["beard", "hammer", "brand", "belly", "forge", "brew", "fist", "helm", "mantle", "delve", "axe"],
        ["hild", "lda", "etta", "grit", "mead", "braid", "dra", "wyn", "ra", "gerd"]),
    4: (["Moon", "Star", "Thal", "Night", "Elune", "Silver", "Dew", "Leaf", "Sylver", "Glimmer", "Mist",
         "Shade", "Willow", "Fern", "Dawn", "Bough", "Lunar", "Thorn", "Raven", "Glade"],
        ["vale", "warden", "shade", "brook", "orien", "strider", "song", "runner", "bough", "wind"],
        ["whisper", "bloom", "lle", "fern", "petal", "glimmer", "leaf", "ara", "wyn", "iel"]),
    5: (["Gravel", "Bone", "Mourn", "Wisp", "Night", "Morrow", "Bleak", "Cinder", "Crypt", "Hollow", "Gloam",
         "Raven", "Rot", "Sorrow", "Ashen", "Dusk", "Dread", "Grave", "Grim", "Pale", "Tomb", "Wither"],
        ["moan", "chatter", "shroud", "gast", "vail", "mere", "moor", "whistle", "pike", "mire", "wick"],
        ["elle", "grave", "rose", "ley", "ira", "in", "veil", "ieve", "wyn", "ora"]),
    6: (["Sky", "Dawn", "Horn", "Mesa", "Storm", "Meadow", "Sage", "Grass", "Rain", "Willow", "Oak", "Thunder",
         "Earth", "River", "Plains", "Totem", "Mist", "Prairie", "Stone", "Wind", "Cloud", "Hawk"],
        ["mane", "blower", "runner", "hoof", "walker", "horn", "back", "hide", "roar", "grazer", "strider"],
        ["song", "bloom", "braid", "grass", "song", "feather", "dance", "leaf", "rain", "sky"]),
    7: (["Giz", "Bolt", "Cog", "Fizzle", "Sprocket", "Widget", "Nimble", "Sprinkle", "Gear", "Spark", "Tinker",
         "Pip", "Wobble", "Fuse", "Crank", "Rivet", "Zap", "Doodle"],
        ["crank", "whistle", "spanner", "bolt", "gear", "wick", "sprock", "tock", "bang"],
        ["mella", "pop", "etta", "ina", "bell", "fizz", "pip", "etti", "ella"]),
    8: (["Mojo", "Zal", "Ju", "Maz", "Ven", "Tikka", "Talun", "Zin", "Yan", "Zan", "Hex", "Tusk", "Zen",
         "Koz", "Vol", "Raz", "Jin", "Zul", "Ush", "Kal"],
        ["zan", "jiro", "maku", "jari", "ru", "ji", "gash", "tuk", "zoth", "jin"],
        ["yra", "zika", "zara", "ka", "jara", "zeda", "laka", "vara", "anji", "ya"]),
    9: (["Fuse", "Gild", "Rivet", "Coin", "Grease", "Scrap", "Gold", "Spark", "Nitro", "Blast", "Profit",
         "Haggle", "Sprock", "Grub", "Bilge", "Tin", "Wrench", "Nugget"],
        ["whisk", "snatch", "fist", "grin", "fuse", "tooth", "bolt", "pocket", "crank", "nose"],
        ["rixa", "etta", "ina", "ella", "ixa", "zee", "ette", "etti", "ia"]),
    10: (["Aure", "Sel", "Elar", "Sun", "Dawn", "Quel", "Thal", "Vael", "Lor", "Sil", "Ael", "Fair", "Gold",
          "Ember", "Ash", "Star", "Bright", "Veil"],
         ["vaelor", "marrow", "strider", "dar", "thas", "orin", "lion", "blade", "wind", "anor"],
         ["lith", "vanne", "yssa", "lilie", "rithel", "wyn", "iel", "ara", "dria", "enne"]),
}


def valid_name(name):
    return (2 <= len(name) <= 12 and name.isalpha() and name[0].isupper() and name[1:].islower()
            and not any(a == b == c for a, b, c in zip(name, name[1:], name[2:])))


def make_names(bots, taken, seed):
    """One new name per bot, deterministic for the seed, in the race's style."""
    used = {n.lower() for n in taken}
    out = {}
    for b in bots:
        heads, male, female = NAME_PARTS[b["race"]]
        tails = male if b["gender"] == 0 else female
        combos = [h + t for h in heads for t in tails if t not in h.lower()]  # no "Pippip"
        combos.sort(key=lambda n: hashlib.sha256(f"{seed}|{b['race']}|{b['gender']}|{n}".encode()).hexdigest())
        for n in combos:
            n = n[0] + n[1:].lower()
            if valid_name(n) and n.lower() not in used:
                used.add(n.lower())
                out[b["guid"]] = n
                break
        else:
            fail(f"no free name left for race {b['race']} gender {b['gender']}")
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True, help="current roster plan CSV (ordinals 1..K)")
    ap.add_argument("--catalog", required=True)
    ap.add_argument("--specs", required=True, action="append", help="spec-role TSV; repeatable")
    ap.add_argument("--target", type=int, required=True)
    ap.add_argument("--per-faction", required=True, help="tanks,healers,dps per faction")
    ap.add_argument("--cap", type=int, required=True, help="max bots per race x class x role (whole roster)")
    ap.add_argument("--catalog-sources", default="live,new-178,new-165",
                    help="catalog sources new slots may use (e.g. 'live' = no factory run)")
    ap.add_argument("--replace-excess", action="store_true",
                    help="REPLACE bots of races above their even share (owner decision, wave 1)")
    ap.add_argument("--levels", help="TSV guid level of the base members (REPLACE picks the lowest)")
    ap.add_argument("--replace-out", help="output: TSV ordinal old_guid new_guid for the REPLACE request")
    ap.add_argument("--respec-tanks", action="store_true",
                    help="respec tanks of a class above its equal share to DPS (owner decision, wave 2)")
    ap.add_argument("--respec-out", help="output: TSV ordinal guid old_path new_path for A6")
    ap.add_argument("--healer-min", type=int, default=0,
                    help="#518: at least N healers of every healer class per faction (N = guilds)")
    ap.add_argument("--class-role-max", default="",
                    help="#518: hard limits per faction, e.g. 'H:2:TANK:3,H:2:DPS:0' (faction:class:role:n)")
    ap.add_argument("--female-share", type=float,
                    help="#518 owner: target share of women per faction, e.g. 0.55")
    ap.add_argument("--summary-out", help="output: markdown summary with the group capacity table")
    ap.add_argument("--demand", required=True, help="output: candidate demand TSV")
    ap.add_argument("--slots-out", help="output: the planned slots before the fill (review)")
    ap.add_argument("--pool", help="free pool TSV: guid account name race class gender level")
    ap.add_argument("--taken-names", action="append", default=[],
                    help="file with names in use (one per line or rename TSV); repeatable")
    ap.add_argument("--name-seed", default="twow-366-308")
    ap.add_argument("--out")
    ap.add_argument("--names-out")
    args = ap.parse_args(argv)

    with open(args.base, newline="", encoding="utf-8") as f:
        base = list(csv.DictReader(f))
    fields = list(base[0].keys())
    if [int(r["ordinal"]) for r in base] != list(range(1, len(base) + 1)):
        fail("base plan ordinals must be 1..K")
    sources = set(args.catalog_sources.split(","))
    known = {(int(r), int(c)): src for r, c, src, *_ in read_tsv(args.catalog)}
    catalog = {pair for pair, src in known.items() if src in sources}
    specs = [(int(c), p, role) for path in args.specs for c, p, role, *_ in read_tsv(path)]
    for _, _, role in specs:
        if role not in ROLES:
            fail(f"unknown role {role}")
    per_faction = [int(x) for x in args.per_faction.split(",")]
    if len(per_faction) != 3:
        fail("--per-faction needs tanks,healers,dps")

    levels = {int(g): int(l) for g, l, *_ in read_tsv(args.levels)} if args.levels else {}
    respecs = []
    class_role_max = {}
    for item in filter(None, args.class_role_max.split(",")):
        fa, cls, role, n = item.split(":")
        if fa not in ("A", "H") or role not in ROLES:
            fail(f"bad --class-role-max item {item}")
        class_role_max[(fa, int(cls), role)] = int(n)
    if args.female_share is not None and not 0 <= args.female_share <= 1:
        fail("--female-share must be between 0 and 1")
    slots = plan_slots(base, catalog, set(known), specs, args.target, per_faction, args.cap,
                       args.replace_excess, levels, args.respec_tanks, respecs,
                       args.healer_min, class_role_max, args.female_share)
    replaced = {s["replace"] for s in slots if "replace" in s}
    by_ordinal = {r["ordinal"]: r for r in respecs}
    base = [dict(r, talent_path=by_ordinal[int(r["ordinal"])]["path"], role="DPS",
                 selection_reason=r["selection_reason"] + "; respec TANK->DPS (owner 20 % tank classes)")
            if int(r["ordinal"]) in by_ordinal else r for r in base]
    kept = [r for r in base if int(r["ordinal"]) not in replaced]
    assign_professions(kept, slots, args.target)
    ordinal = len(base)
    for s in slots:
        if "replace" in s:
            s["ordinal"] = s["replace"]
        else:
            ordinal += 1
            s["ordinal"] = ordinal

    pool = None
    if args.pool:
        taken = {int(r["guid"]) for r in base}
        pool = []
        for guid, account, name, race, cls, gender, level in read_tsv(args.pool):
            if int(guid) not in taken:
                pool.append(dict(guid=int(guid), account=int(account), name=name, race=int(race),
                                 cls=int(cls), gender=int(gender), level=int(level)))
        pool.sort(key=lambda c: (c["level"], c["guid"]))

    with open(args.demand, "w", newline="", encoding="utf-8") as f:
        f.write("# race\tclass\twant_m\twant_f\tpool_m\tpool_f\tshort_m\tshort_f\tFACTORY\n")
        for row in demand_rows(slots, pool):
            f.write("\t".join(map(str, row)) + "\n")
    if args.slots_out:
        with open(args.slots_out, "w", newline="", encoding="utf-8") as f:
            f.write("# slot\trace\tclass\tgender\ttalent_path\trole\tprofession_pair\n")
            for s in slots:
                f.write(f"{s['ordinal']}\t{s['race']}\t{s['cls']}\t{s['gender']}\t{s['path']}\t{s['role']}\t{s['pair']}\n")
    if args.summary_out:
        with open(args.summary_out, "w", newline="", encoding="utf-8") as f:
            f.write(summary(kept, slots, args.cap))
    print(f"slots={len(slots)} demand_sha256={sha256(args.demand)}")
    if pool is None:
        return 0
    if not (args.out and args.names_out):
        fail("--pool needs --out and --names-out")

    used, fallback = set(), 0
    for s in slots:
        i = s["ordinal"]
        same = [c for c in pool if c["guid"] not in used and c["race"] == s["race"] and c["cls"] == s["cls"]]
        pick = next((c for c in same if c["gender"] == s["gender"]), None) or (same[0] if same else None)
        if pick is None:
            fail(f"pool has no race {s['race']} class {s['cls']} left (ordinal {i}); run the factory first")
        fallback += pick["gender"] != s["gender"]
        used.add(pick["guid"])
        s.update(guid=pick["guid"], account=pick["account"], name=pick["name"], gender=pick["gender"])

    taken_names = {r["name"] for r in base}
    for path in args.taken_names:
        for row in read_tsv(path):
            taken_names.add(row[-1].strip())
    names = make_names(slots, taken_names, args.name_seed)
    pool_hash = sha256(args.pool)
    rows = {int(r["ordinal"]): dict(r) for r in base}
    for s in slots:
        rows[s["ordinal"]] = ({
            "ordinal": s["ordinal"], "guid": s["guid"], "account": s["account"], "name": s["name"],
            "race": s["race"], "class": s["cls"], "gender": s["gender"], "talent_path": s["path"],
            "role": s["role"], "profession_pair": s["pair"],
            "selection_reason": "v5; owner #366 race balance; role, race, rarest class/path/gender, then (level,guid)",
            "source_candidate_hash": pool_hash,
        })
    rows = [rows[k] for k in sorted(rows)]
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    if args.replace_out:
        with open(args.replace_out, "w", newline="", encoding="utf-8") as f:
            for s in sorted((s for s in slots if "replace" in s), key=lambda s: s["ordinal"]):
                f.write(f"{s['ordinal']}\t{s['old_guid']}\t{s['guid']}\n")
    changed = sorted(s["ordinal"] for s in slots)
    print("CHANGED_ORDINALS=" + ",".join(map(str, changed)))
    print("A6_ORDINALS=" + ",".join(map(str, sorted(changed + list(by_ordinal)))))
    if args.respec_out:
        with open(args.respec_out, "w", newline="", encoding="utf-8") as f:
            for r in sorted(respecs, key=lambda r: r["ordinal"]):
                f.write(f"{r['ordinal']}\t{r['guid']}\t{r['old_path']}\t{r['path']}\n")
    with open(args.names_out, "w", newline="", encoding="utf-8") as f:
        for s in sorted(slots, key=lambda s: s["ordinal"]):
            f.write(f"{s['ordinal']}\t{s['guid']}\t{s['name']}\t{s['race']}\t{s['cls']}\t{s['gender']}\t{names[s['guid']]}\n")
    print(f"rows={len(rows)} gender_fallback={fallback} pool_sha256={pool_hash} "
          f"out_sha256={sha256(args.out)} names_sha256={sha256(args.names_out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
