#!/usr/bin/env python3
"""Deterministic 154-bot base roster (twow-repo#366 part 5).

Planning data only; touches no database. Rows 1-136 are taken unchanged from plan v3
(`../expand-272/v4-272-roster-plan.csv`): the re-specced existing roster. Rows 137-154
are 18 new bots from the read-only pool snapshot, so that each faction has 77 =
10 tanks / 20 healers / 47 DPS:

    Alliance: +5 healers          Horde: +5 healers, +8 DPS

Owner requirement: the new healers and DPS are spread over class, race and gender, no
clusters. Every slot takes the (race, gender) combination that, in this order, does not
repeat a class + race + gender among the new bots, is rarest so far among the faction's
bots of the same role, has the rarest race in that role, is rarest in the same class
(ties: race, gender); from it the pool candidate with the lowest (level, guid).

    python3 select_roster_v4_154.py --base ../expand-272/v4-272-roster-plan.csv \
        --pool free-pool-snapshot.tsv --out v4-154-roster-plan.csv
"""
import argparse
import csv
import hashlib
import sys
from collections import Counter

ALLIANCE = {1, 3, 4, 7, 10}
HORDE = {2, 5, 6, 8, 9}


def faction(race):
    return "A" if race in ALLIANCE else "H"


# (faction, class, talent_path, role) per new slot, in ordinal order 137..154.
NEW_SLOTS = [
    ("A", 5, "holy", "HEALER"), ("H", 7, "restoration", "HEALER"), ("H", 8, "fire", "DPS"),
    ("A", 2, "holy", "HEALER"), ("H", 5, "holy", "HEALER"), ("H", 9, "affliction", "DPS"),
    ("A", 11, "restoration", "HEALER"), ("H", 11, "restoration", "HEALER"), ("H", 5, "shadow", "DPS"),
    ("A", 5, "discipline", "HEALER"), ("H", 7, "restoration", "HEALER"), ("H", 11, "balance", "DPS"),
    ("A", 2, "holy", "HEALER"), ("H", 5, "discipline", "HEALER"), ("H", 8, "frost", "DPS"),
    ("H", 9, "destruction", "DPS"), ("H", 11, "feral", "DPS"), ("H", 1, "fury", "DPS"),
]

# Profession pairs for the 18 so that all 154 follow the owner's shares (HA 20 %,
# TE 18 %, SL 18 %, MB 12 %, ME 10 %, MJ 8 %, double gatherers 14 %) as closely as the
# existing 136 allow: 154 = HA 31, TE 28, SL 28, MB 18, ME 15, MJ 12, pair 7 22.
PROFESSIONS = [
    ("Mining/Blacksmithing", 1, [1]),
    ("Skinning/Leatherworking", 4, [11, 7]),
    ("Mining/Engineering", 2, [8, 9]),
    ("Tailoring/Enchanting", 3, [8, 5, 9]),
    ("Herbalism/Alchemy", 4, [5, 2, 11, 7]),
    ("Mining/Jewelcrafting", 1, [2, 5]),
    ("Herbalism/Mining", 3, []),
]


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest().upper()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--pool", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.base, newline="", encoding="utf-8") as f:
        base = list(csv.DictReader(f))
    fields = list(base[0].keys())
    existing = base[:136]
    if [int(r["ordinal"]) for r in existing] != list(range(1, 137)):
        sys.exit("base plan must start with ordinals 1..136")
    pool_hash = sha256(args.pool)
    taken = {int(r["guid"]) for r in base}  # never reuse a GUID of the whole 272 plan either
    pool = []
    with open(args.pool, newline="", encoding="utf-8") as f:
        for guid, account, name, race, cls, gender, level in csv.reader(f, delimiter="\t"):
            if int(guid) not in taken:
                pool.append(dict(guid=int(guid), account=int(account), name=name, race=int(race),
                                 cls=int(cls), gender=int(gender), level=int(level)))
    pool.sort(key=lambda c: (c["level"], c["guid"]))

    roster = [dict(race=int(r["race"]), cls=int(r["class"]), gender=int(r["gender"]), role=r["role"]) for r in existing]
    used, new = set(), []
    for i, (fa, cls, path, role) in enumerate(NEW_SLOTS, start=137):
        combos = sorted({(c["race"], c["gender"]) for c in pool if c["cls"] == cls and faction(c["race"]) == fa
                         and c["guid"] not in used})
        if not combos:
            sys.exit(f"pool has no class {cls} for faction {fa}")
        same_role = Counter((b["race"], b["gender"]) for b in roster if faction(b["race"]) == fa and b["role"] == role)
        same_class = Counter((b["race"], b["gender"]) for b in roster if faction(b["race"]) == fa and b["cls"] == cls)
        race_role = Counter(b["race"] for b in roster if faction(b["race"]) == fa and b["role"] == role)
        # never repeat a class + race + gender among the new bots while another combination is free
        new_twin = Counter((b["race"], b["gender"]) for b in new if b["cls"] == cls)
        best = min(combos, key=lambda k: (new_twin[k], same_role[k], race_role[k[0]], same_class[k], k))
        c = next(c for c in pool if c["cls"] == cls and (c["race"], c["gender"]) == best and c["guid"] not in used)
        used.add(c["guid"])
        bot = dict(c, ordinal=i, path=path, role=role)
        roster.append(bot)
        new.append(bot)

    for label, count, prefer in PROFESSIONS:
        need = count
        for pass_class in list(prefer) + [None]:
            for bot in new:
                if need == 0:
                    break
                if "pair" in bot or (pass_class is not None and bot["cls"] != pass_class):
                    continue
                bot["pair"] = label
                need -= 1
        if need:
            sys.exit(f"could not place {label}")

    rows = [dict(r) for r in existing]
    for bot in new:
        rows.append({
            "ordinal": bot["ordinal"], "guid": bot["guid"], "account": bot["account"], "name": bot["name"],
            "race": bot["race"], "class": bot["cls"], "gender": bot["gender"],
            "talent_path": bot["path"], "role": bot["role"], "profession_pair": bot["pair"],
            "selection_reason": "v4_154; owner #366 part 5; rarest race/gender per role and class, then (level,guid)",
            "source_candidate_hash": pool_hash,
        })
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print(f"rows={len(rows)} pool_sha256={pool_hash} out_sha256={sha256(args.out)}")


if __name__ == "__main__":
    main()
