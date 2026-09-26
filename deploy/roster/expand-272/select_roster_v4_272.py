#!/usr/bin/env python3
"""Deterministic selection of roster ordinals 137-272 (twow-repo#366).

Planning data only: reads the immutable 136 prefix and a read-only snapshot of the
free RNDBOT pool, writes the 272-row plan CSV. It touches no database.

    python3 select_roster_v4_272.py --prefix ../v4-136-profession-prefix.csv \
        --pool free-pool-snapshot.tsv --out v4-272-roster-plan.csv

Targets come from the owner decisions D-A..D-C (#366, 2026-09-26): 20 % tanks over
272, one extra bear per druid race, professions per the target table. Same inputs
always give the same output: candidates are taken by (level, guid).
"""
import argparse
import csv
import hashlib
import sys
from collections import OrderedDict

ALLIANCE = {1, 3, 4, 7, 10}  # human, dwarf, night elf, gnome, high elf
HORDE = {2, 5, 6, 8, 9}      # orc, undead, tauren, troll, goblin

# class -> ordered list of (talent_path, role, count); counts sum to 136.
SPECS = OrderedDict([
    (1, [("protection", "TANK", 30)]),
    (2, [("protection", "TANK", 13), ("holy", "HEALER", 4), ("retribution", "DPS", 2)]),
    (11, [("bear", "TANK", 4), ("restoration", "HEALER", 2), ("balance", "DPS", 2), ("feral", "DPS", 2)]),
    (5, [("discipline", "HEALER", 5), ("holy", "HEALER", 5), ("shadow", "DPS", 4)]),
    (7, [("restoration", "HEALER", 5), ("elemental", "DPS", 3), ("enhancement", "DPS", 3)]),
    (3, [("beastmastery", "DPS", 5), ("marksmanship", "DPS", 5), ("survival", "DPS", 4)]),
    (4, [("assassination", "DPS", 5), ("combat", "DPS", 5), ("subtlety", "DPS", 4)]),
    (8, [("arcane", "DPS", 5), ("fire", "DPS", 5), ("frost", "DPS", 3)]),
    (9, [("affliction", "DPS", 4), ("demonology", "DPS", 4), ("destruction", "DPS", 3)]),
])

# Fixed race quotas where the plan prescribes them (#366 composition plan).
FIXED_RACES = {
    (1, "protection"): {2: 4, 6: 5, 5: 3, 8: 3, 9: 3, 1: 3, 3: 3, 4: 3, 7: 2, 10: 1},
    (2, "protection"): {1: 5, 3: 4, 10: 4},  # >= 2 per race so both genders are covered
    (2, None): {1: 2, 3: 1, 10: 3},  # holy + retribution
    (11, "bear"): {4: 2, 6: 2},  # one per race x gender (owner D-B variant)
    (11, None): {4: 3, 6: 3},  # the other six druids
}
# Tank paths alternate gender per race: owner D-B + tank coverage rule (#366,
# 2026-09-26): every tank class covers every available race x gender combination.
GENDER_SPLIT = {(11, "bear"), (1, "protection"), (2, "protection")}
NEW_ALLIANCE_TARGET = 64
NEW_HORDE_TARGET = 72

# Profession pairs, filled in this order; each takes all bots of its first preferred
# class, then the next preferred class, ..., then any remaining bot (ordinal order).
PROFESSIONS = [
    ("Mining/Blacksmithing", 33, [1, 2]),
    ("Mining/Engineering", 27, [3, 4, 1]),
    ("Tailoring/Enchanting", 3, [8, 5, 9]),
    ("Herbalism/Mining", 22, [4, 3, 11, 7]),  # double gatherer; core value pending (OB-10)
    ("Mining/Jewelcrafting", 22, [2, 5]),
    ("Herbalism/Alchemy", 29, [5, 8, 9, 7, 11]),
]


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest().upper()


def load_pool(path, taken):
    pool = []
    with open(path, newline="", encoding="utf-8") as f:
        for row in csv.reader(f, delimiter="\t"):
            guid, account, name, race, cls, gender, level = row
            if int(guid) in taken:
                continue
            pool.append(dict(guid=int(guid), account=int(account), name=name, race=int(race),
                             cls=int(cls), gender=int(gender), level=int(level)))
    pool.sort(key=lambda c: (c["level"], c["guid"]))
    return pool


def split_even(n, keys):
    """n split over keys as evenly as possible, earlier keys get the remainder."""
    base, rest = divmod(n, len(keys))
    return {k: base + (1 if i < rest else 0) for i, k in enumerate(keys)}


def race_quotas(pool):
    races_by_class = {}
    for c in pool:
        races_by_class.setdefault(c["cls"], set()).add(c["race"])
    quotas = {}  # (cls, path) -> {race: n}
    alliance = horde = 0
    flexible = []
    for cls, specs in SPECS.items():
        for path, _role, n in specs:
            fixed = FIXED_RACES.get((cls, path)) or FIXED_RACES.get((cls, None))
            if fixed and (cls, path) in FIXED_RACES:
                q = dict(fixed)
            elif fixed:
                q = None  # class-level quota, distributed over the class's paths below
            else:
                flexible.append((cls, path, n))
                continue
            if q is not None:
                quotas[(cls, path)] = q
    # class-level fixed quotas (paladin, non-bear druids): hand races out path by path
    for cls in (2, 11):
        left = dict(FIXED_RACES[(cls, None)])
        for path, _role, n in SPECS[cls]:
            if (cls, path) in quotas:
                continue
            q = {}
            for race in sorted(left):
                take = min(left[race], n - sum(q.values()))
                if take > 0:
                    q[race] = take
                    left[race] -= take
            quotas[(cls, path)] = q
    for q in quotas.values():
        for race, n in q.items():
            alliance += n if race in ALLIANCE else 0
            horde += n if race in HORDE else 0
    # flexible classes: shamans are Horde-only in the pool; the rest share the factions
    a_left, h_left = NEW_ALLIANCE_TARGET - alliance, NEW_HORDE_TARGET - horde
    for cls, path, n in [f for f in flexible if not (races_by_class[f[0]] & ALLIANCE)]:
        quotas[(cls, path)] = split_even(n, sorted(races_by_class[cls] & HORDE))
        h_left -= n
    rest = [f for f in flexible if (cls_races := races_by_class[f[0]]) & ALLIANCE]
    total = sum(n for _c, _p, n in rest)
    exact = [(n * h_left / total) for _c, _p, n in rest]
    h_parts = [int(x) for x in exact]
    for i in sorted(range(len(rest)), key=lambda i: -(exact[i] - h_parts[i]))[: h_left - sum(h_parts)]:
        h_parts[i] += 1
    for (cls, path, n), h in zip(rest, h_parts):
        a = n - h
        q = {}
        if h:
            q.update(split_even(h, sorted(races_by_class[cls] & HORDE)))
        if a:
            q.update(split_even(a, sorted(races_by_class[cls] & ALLIANCE)))
        quotas[(cls, path)] = {r: v for r, v in q.items() if v}
    return quotas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--pool", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.prefix, newline="", encoding="utf-8") as f:
        prefix = list(csv.DictReader(f))
    if len(prefix) != 136 or [int(r["ordinal"]) for r in prefix] != list(range(1, 137)):
        sys.exit("prefix must be the ordered 136-row V4 prefix")
    fields = list(prefix[0].keys())
    taken = {int(r["guid"]) for r in prefix}
    pool = load_pool(args.pool, taken)
    pool_hash = sha256(args.pool)

    quotas = race_quotas(pool)
    used = set()
    by_class = OrderedDict((cls, []) for cls in SPECS)
    for cls, specs in SPECS.items():
        for path, role, n in specs:
            q = quotas[(cls, path)]
            if sum(q.values()) != n:
                sys.exit(f"quota mismatch for class {cls} {path}: {q} != {n}")
            for race, want in sorted(q.items()):
                free = [c for c in pool if c["cls"] == cls and c["race"] == race and c["guid"] not in used]
                if (cls, path) in GENDER_SPLIT:
                    # alternate male/female so each race gets both genders
                    picks = []
                    for i in range(want):
                        g = i % 2
                        cand = next((c for c in free if c["gender"] == g and c not in picks), None)
                        if cand:
                            picks.append(cand)
                else:
                    picks = free[:want]
                if len(picks) != want:
                    sys.exit(f"pool too small: class {cls} race {race} needs {want}, has {len(picks)}")
                for c in picks:
                    used.add(c["guid"])
                    by_class[cls].append(dict(c, talent_path=path, role=role))

    # Round-robin over classes so that any later prefix of 137..272 stays mixed.
    ordered, cursors = [], {cls: 0 for cls in by_class}
    while len(ordered) < 136:
        for cls, bots in by_class.items():
            if cursors[cls] < len(bots):
                ordered.append(bots[cursors[cls]])
                cursors[cls] += 1

    for label, count, prefer in PROFESSIONS:
        need = count
        # preferred classes strictly in priority order, then any unassigned bot
        for pass_class in list(prefer) + [None]:
            for bot in ordered:
                if need == 0:
                    break
                if "profession" in bot or (pass_class is not None and bot["cls"] != pass_class):
                    continue
                bot["profession"] = label
                need -= 1
        if need:
            sys.exit(f"could not place {label}")

    rows = list(prefix)
    for i, bot in enumerate(ordered, start=137):
        rows.append({
            "ordinal": i, "guid": bot["guid"], "account": bot["account"], "name": bot["name"],
            "race": bot["race"], "class": bot["cls"], "gender": bot["gender"],
            "talent_path": bot["talent_path"], "role": bot["role"],
            "profession_pair": bot["profession"],
            "selection_reason": "v4_272_expand; owner D-A..D-C #366; quota class/path/race by (level,guid)",
            "source_candidate_hash": pool_hash,
        })
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print(f"rows={len(rows)} pool_sha256={pool_hash} out_sha256={sha256(args.out)}")


if __name__ == "__main__":
    main()
