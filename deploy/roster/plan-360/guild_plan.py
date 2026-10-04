#!/usr/bin/env python3
"""Guild split for a roster plan (#485 owner rule: guilds with balanced roles, 1 guild per ~45 bots per faction,
5 tanks / 10 healers / 30 DPS each). Deterministic, stdlib only, planning only (no DB).

    guild_plan.py plan.csv [--per-guild T,H,D] [--levels guid-level.tsv] [--keep previous-guilds.tsv] [--rare-spread] > guilds.tsv
    (ordinal guid faction guild role class race; the PlanFile of core#309 AiPlayerbot.RosterGuild.PlanFile)

Per faction and role, members are sorted by class, race, ordinal and dealt round-robin over the guilds, so every
guild gets the same role counts and a class spread. With --keep, members that already have a guild keep it and
only the new members are dealt (the 270 -> 360 step: the 4th guild per faction gets the new bots)."""
import csv
import sys
from collections import defaultdict

HORDE = {"2", "5", "6", "8", "9"}
PER_GUILD = {"TANK": 5, "HEALER": 10, "DPS": 30}
if "--per-guild" in sys.argv:  # e.g. 7,10,28
    _t, _h, _d = map(int, sys.argv[sys.argv.index("--per-guild") + 1].split(","))
    PER_GUILD = {"TANK": _t, "HEALER": _h, "DPS": _d}

rows = list(csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8")))
level = {}
if "--levels" in sys.argv:  # guid<TAB>level; bots not listed (new) count as level 1
    for line in open(sys.argv[sys.argv.index("--levels") + 1], encoding="utf-8"):
        g, l = line.split("	")[:2]
        level[g] = int(l)
band = lambda r: (level.get(r["guid"], 1) - 1) // 5  # 5-level bands, so each band is dealt evenly over the guilds
keep = {}
if "--keep" in sys.argv:
    for line in open(sys.argv[sys.argv.index("--keep") + 1], encoding="utf-8"):
        if line.startswith("ordinal"):
            continue
        p = line.rstrip("\n").split("\t")
        keep[p[0]] = p[3]
RARE_SPREAD = "--rare-spread" in sys.argv  # same rule as core#309 AiPlayerbot.RosterGuild.RareComboSpread
out = []
for fac in ("A", "H"):
    members = [r for r in rows if ("H" if r["race"] in HORDE else "A") == fac]
    roles = defaultdict(list)
    for r in members:
        roles[r["role"]].append(r)
    guilds = len(roles["TANK"]) // PER_GUILD["TANK"]
    # --rare-spread (#518, core#309): every race x class pair at most ceil(count / guilds) per guild,
    # over all roles, and the pair count per guild is the second sort key after the class count
    pair_total = defaultdict(int)
    for r in members:
        pair_total[(r["race"], r["class"])] += 1
    pair_guild = defaultdict(int)  # (guild, race, class) -> members of that pair in the guild
    for r in members:
        if r["ordinal"] in keep:
            pair_guild[(keep[r["ordinal"]], r["race"], r["class"])] += 1

    def pair_cap(r):
        return -(-pair_total[(r["race"], r["class"])] // guilds)
    for role, lst in roles.items():
        if len(lst) != guilds * PER_GUILD[role]:
            sys.exit(f"{fac} {role}: {len(lst)} does not split into {guilds} guilds of {PER_GUILD[role]}")
        count = defaultdict(int)        # guild -> members of this role
        cls_count = defaultdict(int)    # (guild, class) -> members of this role and class (#518)
        band_count = defaultdict(int)   # (guild, band) -> members of this role in that level band
        names = [f"{fac}{g + 1}" for g in range(guilds)]
        for r in lst:
            if r["ordinal"] in keep:
                g = keep[r["ordinal"]]
                count[g] += 1
                cls_count[(g, r["class"])] += 1
                band_count[(g, band(r))] += 1
                out.append((r, g))
        # #518: deal class by class (rarest class first), so every guild gets each class of the role
        # (healers: every healer class per guild for buffs/dispels); within a class by level band
        per_class = defaultdict(int)
        for r in lst:
            per_class[r["class"]] += 1
        new = sorted((r for r in lst if r["ordinal"] not in keep),
                     key=lambda r: (per_class[r["class"]], int(r["class"]),
                                    pair_total[(r["race"], r["class"])] if RARE_SPREAD else 0,  # rarer pairs pick first
                                    band(r), int(r["race"]), int(r["ordinal"])))
        for r in new:
            open_g = [n for n in names if count[n] < PER_GUILD[role]]
            if RARE_SPREAD:
                within = [n for n in open_g if pair_guild[(n, r["race"], r["class"])] < pair_cap(r)]
                open_g = within or open_g  # never leave a bot without a guild
                g = min(open_g, key=lambda n: (cls_count[(n, r["class"])], pair_guild[(n, r["race"], r["class"])],
                                               count[n], band_count[(n, band(r))], names.index(n)))
            else:
                g = min(open_g, key=lambda n: (cls_count[(n, r["class"])], count[n], band_count[(n, band(r))], names.index(n)))
            count[g] += 1
            cls_count[(g, r["class"])] += 1
            band_count[(g, band(r))] += 1
            pair_guild[(g, r["race"], r["class"])] += 1
            out.append((r, g))
print("ordinal\tguid\tfaction\tguild\trole\tclass\trace")
for r, g in sorted(out, key=lambda x: int(x[0]["ordinal"])):
    print(f"{r['ordinal']}\t{r['guid']}\t{g[0]}\t{g}\t{r['role']}\t{r['class']}\t{r['race']}")
