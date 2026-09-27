#!/usr/bin/env python3
"""Race-balanced roster expansion for any size (twow-repo#366, owner requirement 2026-09-27).

Planning data only; touches no database. The rows of the current roster plan (--base) stay
unchanged as ordinals 1..K (EXPAND keeps the prefix). The new rows K+1..N are planned in
two steps:

1. Slots, without any pool. Per faction:
   - every race ends within +-1 of the faction's size / 5 (hard);
   - tanks / healers / DPS end at --per-faction (hard);
   - bears end at --bears-per-race-gender for each race x gender that has druids (hard);
   - otherwise each slot takes, in this order: the role furthest behind its target; among the
     races that keep all targets reachable, the one with the smallest share of that role, then
     the one furthest behind its size; the class of that race and role that is rarest in the
     race; the rarest talent path; the rarest gender for that race and class. Only pairs of
     --catalog and paths of --specs are used.
   `--demand` writes the slots as candidate demand per race x class x gender. Compared with
   a pool snapshot it gives the number of bots the factory must create (FACTORY column).
2. Fill (--pool): every slot takes the free pool character of its race and class, same
   gender first, lowest (level, guid). New names come from --names-out.

    python3 select_roster_v5.py --base ../plan-154/v4-154-roster-plan.csv --target 308 \
        --per-faction 20,40,94 --bears-per-race-gender 2 --demand demand.tsv [--pool pool.tsv \
        --taken-names names.txt --out v5-308-roster-plan.csv --names-out new-names.tsv]
"""
import argparse
import csv
import hashlib
import itertools
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


def feasible(race_rem, role_rem, can):
    """Transportation feasibility: the remaining race counts can take the remaining roles."""
    if sum(race_rem.values()) != sum(role_rem.values()):
        return False
    roles = [r for r in ROLES if role_rem[r] > 0]
    for n in range(1, len(roles) + 1):
        for subset in itertools.combinations(roles, n):
            supply = sum(race_rem[race] for race in race_rem if any(can[race][r] for r in subset))
            if sum(role_rem[r] for r in subset) > supply:
                return False
    return True


def plan_slots(base, catalog, specs, target, per_faction, bears_per_rg):
    """Return the new slots in ordinal order: dicts race, cls, gender, path, role."""
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
                   path=r["talent_path"], role=r["role"]) for r in base]
    for b in roster:
        if (b["race"], b["cls"]) not in catalog:
            fail(f"base row race {b['race']} class {b['cls']} is not in the catalog")
    per_faction_slots = {}
    for fa, races in (("A", ALLIANCE), ("H", HORDE)):
        mine = [b for b in roster if faction(b["race"]) == fa]
        have_race = Counter(b["race"] for b in mine)
        low, extra = divmod(half, len(races))
        # the +1 goes to the races that already have the most bots, so nobody must shrink
        order = sorted(races, key=lambda r: (-have_race[r], r))
        race_target = {r: low + (1 if i < extra else 0) for i, r in enumerate(order)}
        race_rem = {r: race_target[r] - have_race[r] for r in races}
        for r, n in race_rem.items():
            if n < 0:
                fail(f"race {r} already has {have_race[r]} bots, above its target {race_target[r]}; "
                     "only a REPLACE could balance it")
        have_role = Counter(b["role"] for b in mine)
        role_rem = {r: role_target[r] - have_role[r] for r in ROLES}
        for r, n in role_rem.items():
            if n < 0:
                fail(f"faction {fa} already has {have_role[r]} {r}, above {role_target[r]}")
        can = {race: {role: any((race, c) in catalog and paths.get((c, role)) for c in {c for _, c in catalog})
                      for role in ROLES} for race in races}
        slots = []

        def take(race, cls, gender, path, role):
            s = dict(race=race, cls=cls, gender=gender, path=path, role=role)
            slots.append(s)
            mine.append(s)
            race_rem[race] -= 1
            role_rem[role] -= 1

        # bears first: they are a hard count per race x gender
        for race in races:
            if (race, DRUID) not in catalog or "bear" not in paths.get((DRUID, "TANK"), []):
                continue
            for gender in (0, 1):
                have = sum(1 for b in mine if b["race"] == race and b["gender"] == gender and b["path"] == "bear")
                for _ in range(bears_per_rg - have):
                    take(race, DRUID, gender, "bear", "TANK")
        if not feasible(race_rem, role_rem, can):
            fail(f"faction {fa}: race and role targets cannot both be met")
        total_new = {r: max(role_rem[r], 1) for r in ROLES}
        while sum(role_rem.values()):
            for role in sorted(ROLES, key=lambda r: (-role_rem[r] / total_new[r], ROLES.index(r))):
                if role_rem[role] == 0:
                    continue
                options = []
                for race in races:
                    if race_rem[race] == 0 or not can[race][role]:
                        continue
                    race_rem[race] -= 1
                    role_rem[role] -= 1
                    ok = feasible(race_rem, role_rem, can)
                    race_rem[race] += 1
                    role_rem[role] += 1
                    if ok:
                        have = sum(1 for b in mine if b["race"] == race)
                        in_role = sum(1 for b in mine if b["race"] == race and b["role"] == role)
                        options.append(((in_role / race_target[race], have / race_target[race], race), race))
                if options:
                    break
            else:
                fail(f"faction {fa}: no feasible slot left")
            race = min(options)[1]
            in_race = [b for b in mine if b["race"] == race]
            rc = Counter(b["cls"] for b in in_race)
            rcp = Counter((b["cls"], b["path"]) for b in in_race)
            cells = [(c, p) for (r, c) in catalog if r == race for p in paths.get((c, role), [])
                     if p != "bear"]
            cls, path = min(cells, key=lambda cp: (rc[cp[0]], rcp[cp], cp[0], cp[1]))
            rg = Counter(b["gender"] for b in in_race if b["cls"] == cls)
            g_all = Counter(b["gender"] for b in in_race)
            gender = min((0, 1), key=lambda g: (rg[g], g_all[g], g))
            take(race, cls, gender, path, role)
        per_faction_slots[fa] = slots
    # alternate factions so every stretch of ordinals is mixed
    out = []
    for a, h in itertools.zip_longest(per_faction_slots["A"], per_faction_slots["H"]):
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
        combos = [h + t for h in heads for t in tails]
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
    ap.add_argument("--specs", required=True)
    ap.add_argument("--target", type=int, required=True)
    ap.add_argument("--per-faction", required=True, help="tanks,healers,dps per faction")
    ap.add_argument("--bears-per-race-gender", type=int, required=True)
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
    catalog = {(int(r), int(c)) for r, c, *_ in read_tsv(args.catalog)}
    specs = [(int(c), p, role) for c, p, role, *_ in read_tsv(args.specs)]
    for _, _, role in specs:
        if role not in ROLES:
            fail(f"unknown role {role}")
    per_faction = [int(x) for x in args.per_faction.split(",")]
    if len(per_faction) != 3:
        fail("--per-faction needs tanks,healers,dps")

    slots = plan_slots(base, catalog, specs, args.target, per_faction, args.bears_per_race_gender)
    assign_professions(base, slots, args.target)

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
            for i, s in enumerate(slots, start=len(base) + 1):
                f.write(f"{i}\t{s['race']}\t{s['cls']}\t{s['gender']}\t{s['path']}\t{s['role']}\t{s['pair']}\n")
    print(f"slots={len(slots)} demand_sha256={sha256(args.demand)}")
    if pool is None:
        return 0
    if not (args.out and args.names_out):
        fail("--pool needs --out and --names-out")

    used, fallback = set(), 0
    for i, s in enumerate(slots, start=len(base) + 1):
        same = [c for c in pool if c["guid"] not in used and c["race"] == s["race"] and c["cls"] == s["cls"]]
        pick = next((c for c in same if c["gender"] == s["gender"]), None) or (same[0] if same else None)
        if pick is None:
            fail(f"pool has no race {s['race']} class {s['cls']} left (ordinal {i}); run the factory first")
        fallback += pick["gender"] != s["gender"]
        used.add(pick["guid"])
        s.update(ordinal=i, guid=pick["guid"], account=pick["account"], name=pick["name"], gender=pick["gender"])

    taken_names = {r["name"] for r in base}
    for path in args.taken_names:
        for row in read_tsv(path):
            taken_names.add(row[-1].strip())
    names = make_names(slots, taken_names, args.name_seed)
    pool_hash = sha256(args.pool)
    rows = [dict(r) for r in base]
    for s in slots:
        rows.append({
            "ordinal": s["ordinal"], "guid": s["guid"], "account": s["account"], "name": s["name"],
            "race": s["race"], "class": s["cls"], "gender": s["gender"], "talent_path": s["path"],
            "role": s["role"], "profession_pair": s["pair"],
            "selection_reason": "v5; owner #366 race balance; role, race, rarest class/path/gender, then (level,guid)",
            "source_candidate_hash": pool_hash,
        })
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    with open(args.names_out, "w", newline="", encoding="utf-8") as f:
        for s in slots:
            f.write(f"{s['ordinal']}\t{s['guid']}\t{s['name']}\t{s['race']}\t{s['cls']}\t{s['gender']}\t{names[s['guid']]}\n")
    print(f"rows={len(rows)} gender_fallback={fallback} pool_sha256={pool_hash} "
          f"out_sha256={sha256(args.out)} names_sha256={sha256(args.names_out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
