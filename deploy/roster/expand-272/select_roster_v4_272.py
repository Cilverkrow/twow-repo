#!/usr/bin/env python3
"""Deterministic 272-bot roster plan (twow-repo#366), version 2.

Planning data only: reads the 136 live roster rows (V4 prefix) and a read-only
snapshot of the free RNDBOT pool, writes the 272-row plan CSV and a diff of the
existing 136. It touches no database.

    python3 select_roster_v4_272.py --prefix ../v4-136-profession-prefix.csv \
        --pool free-pool-snapshot.tsv --out v4-272-roster-plan.csv \
        --diff existing-136-diff.csv

Owner decisions (#366, 2026-09-26, part 3): plan all 272 from scratch; tanks 40,
healers 60, DPS 172, factions 136/136; at least one warrior tank per race; 8 bears
(night elf and tauren, each gender twice). The existing 136 keep class, race, gender,
name and level: only talent path/role and profession pair may change, and a bot keeps
its current path whenever that path still has room. New members come from the pool by
(level, guid). Same inputs always give the same output.
"""
import argparse
import csv
import hashlib
import sys
from collections import Counter, OrderedDict

ALLIANCE = {1, 3, 4, 7, 10}
HORDE = {2, 5, 6, 8, 9}
NIGHT_ELF, TAUREN = 4, 6


def faction(race):
    return "A" if race in ALLIANCE else "H"


# (faction, class) -> OrderedDict(path -> (role, count)). Each faction sums to 136.
TARGETS = {
    ("A", 1): OrderedDict([("protection", ("TANK", 10)), ("arms", ("DPS", 4)), ("fury", ("DPS", 4))]),
    ("A", 2): OrderedDict([("protection", ("TANK", 6)), ("holy", ("HEALER", 10)), ("retribution", ("DPS", 4))]),
    ("A", 11): OrderedDict([("bear", ("TANK", 4)), ("restoration", ("HEALER", 4)), ("balance", ("DPS", 2)), ("feral", ("DPS", 2))]),
    ("A", 5): OrderedDict([("discipline", ("HEALER", 8)), ("holy", ("HEALER", 8)), ("shadow", ("DPS", 4))]),
    ("A", 3): OrderedDict([("beastmastery", ("DPS", 6)), ("marksmanship", ("DPS", 6)), ("survival", ("DPS", 6))]),
    ("A", 4): OrderedDict([("assassination", ("DPS", 6)), ("combat", ("DPS", 6)), ("subtlety", ("DPS", 6))]),
    ("A", 8): OrderedDict([("arcane", ("DPS", 6)), ("fire", ("DPS", 5)), ("frost", ("DPS", 5))]),
    ("A", 9): OrderedDict([("affliction", ("DPS", 5)), ("demonology", ("DPS", 4)), ("destruction", ("DPS", 5))]),
    ("H", 1): OrderedDict([("protection", ("TANK", 16)), ("arms", ("DPS", 4)), ("fury", ("DPS", 4))]),
    ("H", 11): OrderedDict([("bear", ("TANK", 4)), ("restoration", ("HEALER", 4)), ("balance", ("DPS", 2)), ("feral", ("DPS", 2))]),
    ("H", 5): OrderedDict([("discipline", ("HEALER", 6)), ("holy", ("HEALER", 6)), ("shadow", ("DPS", 4))]),
    ("H", 7): OrderedDict([("restoration", ("HEALER", 14)), ("elemental", ("DPS", 4)), ("enhancement", ("DPS", 4))]),
    ("H", 3): OrderedDict([("beastmastery", ("DPS", 6)), ("marksmanship", ("DPS", 6)), ("survival", ("DPS", 6))]),
    ("H", 4): OrderedDict([("assassination", ("DPS", 6)), ("combat", ("DPS", 5)), ("subtlety", ("DPS", 5))]),
    ("H", 8): OrderedDict([("arcane", ("DPS", 5)), ("fire", ("DPS", 5)), ("frost", ("DPS", 4))]),
    ("H", 9): OrderedDict([("affliction", ("DPS", 5)), ("demonology", ("DPS", 4)), ("destruction", ("DPS", 5))]),
}
# Bears: exact (race, gender) slots; each gender twice per race.
BEAR_SLOTS = {"A": Counter({(NIGHT_ELF, 0): 2, (NIGHT_ELF, 1): 2}),
              "H": Counter({(TAUREN, 0): 2, (TAUREN, 1): 2})}

# Ordinals 1-136 alone must already follow the owner's rules (#366 part 4: they are
# re-specced and reset before any expansion): exactly half of the 272 target, built from
# the classes the existing bots have. The new 137-272 get TARGETS minus this.
EXISTING_TARGETS = {
    ("A", 1): OrderedDict([("protection", 5), ("arms", 4), ("fury", 4)]),
    ("A", 2): OrderedDict([("protection", 3), ("holy", 5), ("retribution", 2)]),
    ("A", 11): OrderedDict([("bear", 2), ("restoration", 1), ("balance", 0), ("feral", 0)]),
    ("A", 5): OrderedDict([("discipline", 5), ("holy", 4), ("shadow", 4)]),
    ("A", 3): OrderedDict([("beastmastery", 4), ("marksmanship", 4), ("survival", 4)]),
    ("A", 4): OrderedDict([("assassination", 4), ("combat", 4), ("subtlety", 4)]),
    ("A", 8): OrderedDict([("arcane", 2), ("fire", 2), ("frost", 1)]),
    ("A", 9): OrderedDict([("affliction", 2), ("demonology", 1), ("destruction", 1)]),
    ("H", 1): OrderedDict([("protection", 8), ("arms", 2), ("fury", 1)]),
    ("H", 11): OrderedDict([("bear", 2), ("restoration", 1), ("balance", 0), ("feral", 0)]),
    ("H", 5): OrderedDict([("discipline", 2), ("holy", 2), ("shadow", 1)]),
    ("H", 7): OrderedDict([("restoration", 10), ("elemental", 1), ("enhancement", 1)]),
    ("H", 3): OrderedDict([("beastmastery", 4), ("marksmanship", 3), ("survival", 3)]),
    ("H", 4): OrderedDict([("assassination", 4), ("combat", 3), ("subtlety", 3)]),
    ("H", 8): OrderedDict([("arcane", 3), ("fire", 2), ("frost", 2)]),
    ("H", 9): OrderedDict([("affliction", 2), ("demonology", 2), ("destruction", 2)]),
}
EXISTING_BEAR_SLOTS = {"A": Counter({(NIGHT_ELF, 0): 1, (NIGHT_ELF, 1): 1}),
                       "H": Counter({(TAUREN, 0): 1, (TAUREN, 1): 1})}

# Profession pairs (owner table, #366), filled in this order; each takes all unassigned
# bots of its first preferred class, then the next class, ..., then anyone. The existing
# 136 get half of the 272 table; the new 136 get the rest.
PROFESSIONS = [
    ("Mining/Blacksmithing", 33, 17, [1]),
    ("Skinning/Leatherworking", 49, 24, [4, 11, 3, 7]),
    ("Mining/Engineering", 27, 13, [3, 4, 1]),
    ("Tailoring/Enchanting", 49, 25, [8, 5, 9]),
    ("Herbalism/Alchemy", 54, 27, [5, 2, 11, 7, 8, 9]),
    ("Mining/Jewelcrafting", 22, 11, [2, 5, 7]),
    ("Herbalism/Mining", 38, 19, []),  # double gatherers (ProfessionPair 7, core#161)
]
ROLE_ORDER = {"TANK": 0, "HEALER": 1, "DPS": 2}


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest().upper()


def split_even(n, keys):
    base, rest = divmod(n, len(keys))
    return {k: base + (1 if i < rest else 0) for i, k in enumerate(keys)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--pool", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--diff", required=True)
    args = ap.parse_args()

    with open(args.prefix, newline="", encoding="utf-8") as f:
        prefix = list(csv.DictReader(f))
    if len(prefix) != 136 or [int(r["ordinal"]) for r in prefix] != list(range(1, 137)):
        sys.exit("prefix must be the ordered 136-row V4 prefix")
    fields = list(prefix[0].keys())
    pool_hash = sha256(args.pool)
    taken = {int(r["guid"]) for r in prefix}
    pool = []
    with open(args.pool, newline="", encoding="utf-8") as f:
        for guid, account, name, race, cls, gender, level in csv.reader(f, delimiter="\t"):
            if int(guid) not in taken:
                pool.append(dict(guid=int(guid), account=int(account), name=name, race=int(race),
                                 cls=int(cls), gender=int(gender), level=int(level)))
    pool.sort(key=lambda c: (c["level"], c["guid"]))

    existing = [dict(ordinal=int(r["ordinal"]), guid=int(r["guid"]), account=int(r["account"]), name=r["name"],
                     race=int(r["race"]), cls=int(r["class"]), gender=int(r["gender"]),
                     old_path=r["talent_path"], old_role=r["role"], old_pair=r["profession_pair"], row=r)
                for r in prefix]

    # Phase 1 capacities: the half target for the existing 136.
    cap = {(fa, cl, p): n for (fa, cl), paths in EXISTING_TARGETS.items() for p, n in paths.items()}
    bear_left = {fa: Counter(s) for fa, s in EXISTING_BEAR_SLOTS.items()}
    for (fa, cl), paths in TARGETS.items():
        if set(paths) != set(EXISTING_TARGETS[(fa, cl)]):
            sys.exit(f"EXISTING_TARGETS paths differ for {fa} class {cl}")

    def take(bot, path):
        key = (faction(bot["race"]), bot["cls"], path)
        if cap.get(key, 0) <= 0:
            sys.exit(f"no capacity for {key}")
        cap[key] -= 1
        bot["path"] = path
        bot["role"] = TARGETS[key[:2]][path][0]

    # 1. existing druids: bears first (exact race/gender slots).
    for bot in existing:
        if bot["cls"] == 11:
            fa, slot = faction(bot["race"]), (bot["race"], bot["gender"])
            if bear_left[fa][slot] > 0:
                bear_left[fa][slot] -= 1
                take(bot, "bear")
    # 2. existing warriors: one protection tank per race (lowest ordinal of that race).
    covered = set()
    for bot in existing:
        if bot["cls"] == 1 and bot["race"] not in covered:
            covered.add(bot["race"])
            take(bot, "protection")
    # 3. everyone else keeps the current path if it still has room ...
    for bot in existing:
        if "path" not in bot:
            key = (faction(bot["race"]), bot["cls"], bot["old_path"])
            if cap.get(key, 0) > 0:
                take(bot, bot["old_path"])
    # ... otherwise the first non-bear path of the class that has room (roster order).
    for bot in existing:
        if "path" in bot:
            continue
        fa = faction(bot["race"])
        for path in TARGETS[(fa, bot["cls"])]:
            if path != "bear" and cap[(fa, bot["cls"], path)] > 0:
                take(bot, path)
                break
        else:
            sys.exit(f"no room for existing bot {bot['guid']} class {bot['cls']}")
    if any(v != 0 for v in cap.values()) or any(n for c in bear_left.values() for n in c.values()):
        sys.exit(f"existing 136 do not fill their half target: { {k: v for k, v in cap.items() if v} }")

    # Phase 2 capacities: the full target minus what the existing 136 took.
    used_by_existing = Counter((faction(b["race"]), b["cls"], b["path"]) for b in existing)
    cap = {(fa, cl, p): n - used_by_existing[(fa, cl, p)]
           for (fa, cl), paths in TARGETS.items() for p, (_r, n) in paths.items()}
    if any(v < 0 for v in cap.values()):
        sys.exit(f"half target exceeds the full target: { {k: v for k, v in cap.items() if v < 0} }")
    bear_used = Counter((faction(b["race"]), b["race"], b["gender"]) for b in existing if b["path"] == "bear")
    bear_left = {fa: Counter({slot: n - bear_used[(fa,) + slot] for slot, n in s.items()}) for fa, s in BEAR_SLOTS.items()}

    # 4. new members fill every remaining slot from the pool.
    used = set(taken)
    new = []
    for fa in ("A", "H"):
        for (bear_race, gender), n in sorted(bear_left[fa].items()):
            for _ in range(n):
                c = next((c for c in pool if c["cls"] == 11 and c["race"] == bear_race
                          and c["gender"] == gender and c["guid"] not in used), None)
                if not c:
                    sys.exit(f"pool has no druid race {bear_race} gender {gender}")
                used.add(c["guid"])
                bot = dict(c)
                take(bot, "bear")
                new.append(bot)
        for (f2, cls), paths in TARGETS.items():
            if f2 != fa:
                continue
            races = sorted({c["race"] for c in pool if c["cls"] == cls} & (ALLIANCE if fa == "A" else HORDE))
            for path in paths:
                n = cap[(fa, cls, path)]
                if n <= 0:
                    continue
                for race, want in sorted(split_even(n, races).items()):
                    got = [c for c in pool if c["cls"] == cls and c["race"] == race and c["guid"] not in used][:want]
                    for c in got:
                        used.add(c["guid"])
                    if len(got) < want:  # race ran short: take other races of the faction
                        extra = [c for c in pool if c["cls"] == cls and c["race"] in races
                                 and c["guid"] not in used][: want - len(got)]
                        for c in extra:
                            used.add(c["guid"])
                        got += extra
                    if len(got) != want:
                        sys.exit(f"pool too small for {fa} class {cls} {path}")
                    for c in got:
                        bot = dict(c)
                        take(bot, path)
                        new.append(bot)
    if len(new) != 136 or any(v != 0 for v in cap.values()):
        sys.exit(f"plan does not close: new={len(new)} open={ {k: v for k, v in cap.items() if v} }")

    # New ordinals 137..272: round-robin over classes (tanks and healers first within a
    # class) so that any later prefix stays mixed.
    groups = OrderedDict()
    for bot in sorted(new, key=lambda b: (b["cls"], ROLE_ORDER[b["role"]], b["guid"])):
        groups.setdefault(bot["cls"], []).append(bot)
    ordered, cursors = [], {k: 0 for k in groups}
    while len(ordered) < 136:
        for k, bots in groups.items():
            if cursors[k] < len(bots):
                ordered.append(bots[cursors[k]])
                cursors[k] += 1
    for i, bot in enumerate(ordered, start=137):
        bot["ordinal"] = i

    # Professions: class fit in priority order, roster order within a class; the existing
    # 136 take half of the table, the new 136 the rest.
    for group, idx in ((existing, 2), (ordered, None)):
        for entry in PROFESSIONS:
            label, total, half, prefer = entry
            need = half if idx else total - half
            for pass_class in list(prefer) + [None]:
                for bot in group:
                    if need == 0:
                        break
                    if "pair" in bot or (pass_class is not None and bot["cls"] != pass_class):
                        continue
                    bot["pair"] = label
                    need -= 1
            if need:
                sys.exit(f"could not place {label}")

    rows = []
    for bot in existing:
        r = dict(bot["row"])
        r.update(talent_path=bot["path"], role=bot["role"], profession_pair=bot["pair"])
        rows.append(r)
    for bot in ordered:
        rows.append({
            "ordinal": bot["ordinal"], "guid": bot["guid"], "account": bot["account"], "name": bot["name"],
            "race": bot["race"], "class": bot["cls"], "gender": bot["gender"],
            "talent_path": bot["path"], "role": bot["role"], "profession_pair": bot["pair"],
            "selection_reason": "v4_272_v2; owner #366 part 3; quota faction/class/path by (level,guid)",
            "source_candidate_hash": pool_hash,
        })
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)

    with open(args.diff, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["ordinal", "guid", "name", "race", "class", "old_path", "new_path", "old_role", "new_role",
                    "old_pair", "new_pair", "respec", "profession_change"])
        for bot in existing:
            w.writerow([bot["ordinal"], bot["guid"], bot["name"], bot["race"], bot["cls"], bot["old_path"],
                        bot["path"], bot["old_role"], bot["role"], bot["old_pair"], bot["pair"],
                        int(bot["old_path"] != bot["path"]), int(bot["old_pair"] != bot["pair"])])
    print(f"rows={len(rows)} pool_sha256={pool_hash} out_sha256={sha256(args.out)} diff_sha256={sha256(args.diff)}")


if __name__ == "__main__":
    main()
