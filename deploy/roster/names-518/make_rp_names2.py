#!/usr/bin/env python3
"""#518 RP names v2 (owner 04.10): every bot of the staged plan up to 810.

First name = character name (A5 rules: ^[A-Z][a-z]{1,11}$, no letter three times in a row, unique, not a
character name / ai_playerbot_names entry unless it is the bot's own, not on the lore block list):
  KEEP for current names from our race-style drafts or the owner's keep list; otherwise OB-50's name list
  for race x gender, then OB-40 reserve, then OB-50 syllables (start + end, start + middle + end).
Surname (addon only, may contain spaces): **every surname exactly once** over all bots:
  about 10 % "von <Ort>" (AreaTable places of the race's homeland + owner examples), otherwise surnames
  of NPCs of the race from our world DB (display race), then OB-50 surnames of the race.
Deterministic (sha256 order). Planning only, no DB access.

    make_rp_names2.py <dir with inputs> plan.csv > names.tsv"""
import csv
import hashlib
import re
import sys
from collections import defaultdict

RACES_DE = {"Mensch": 1, "Zwerg": 3, "Nachtelf": 4, "Gnom": 7, "Hochelf": 10,
            "Ork": 2, "Untoter": 5, "Tauren": 6, "Troll": 8, "Goblin": 9}
RACES_EN = {"human": 1, "dwarf": 3, "nightelf": 4, "gnome": 7, "highelf": 10,
            "orc": 2, "undead": 5, "tauren": 6, "troll": 8, "goblin": 9}
RACE_NAME = {v: k for k, v in RACES_DE.items()}
CLASS = {1: "warrior", 2: "paladin", 3: "hunter", 4: "rogue", 5: "priest", 7: "shaman", 8: "mage", 9: "warlock", 11: "druid"}
VALID = re.compile(r"^[A-Z][a-z]{1,11}$")
ORIGIN_SHARE = 0.10
# NPC last words that are no surnames (left after the generic filter)
SURNAME_STOP = {"surveyor", "evacuee", "darkbargainer", "chong", "blump", "bilger", "flathead", "goldfingers",
                "individual", "drummer", "adams", "jacob", "dean", "bell", "marsh", "winter", "smith", "jones"}
CLUMSY = re.compile(r"(ii|uu|aa|[aeiouy]{3})")  # syllable joins like "Bruniis", "Kikeella"


def ok(name):
    return bool(VALID.match(name)) and not re.search(r"(.)\1\1", name.lower())


def h(*parts):
    return hashlib.sha256("|".join(map(str, parts)).encode()).hexdigest()


def lines(path):
    return [l.rstrip("\n") for l in open(path, encoding="utf-8") if l.strip() and not l.startswith("#")]


def main():
    d, plan = sys.argv[1], sys.argv[2]
    first = defaultdict(list)
    ob50_last = defaultdict(list)
    race = None
    for line in open(f"{d}/ob50-names-5978758670.md", encoding="utf-8"):
        m = re.match(r"### (\w+)", line)
        if m:
            race = RACES_DE.get(m.group(1))
            continue
        if race is None:
            continue
        m = re.match(r"- \*\*(Männlich|Weiblich) \(\d+\):\*\* (.+)", line)
        if m:
            first[(race, 0 if m.group(1) == "Männlich" else 1)] = [n.strip() for n in m.group(2).split(",")]
        m = re.match(r"- \*\*Nachnamen \([^)]*\):\*\* (.+)", line)
        if m:
            ob50_last[race] = re.findall(r"([A-Z][A-Za-z]+) \([A-Z]\)", m.group(1))
    for row in lines(f"{d}/reserve-first.tsv"):
        r, g, n = row.split("\t")
        first[(int(r), int(g))].append(n)
    syl = defaultdict(lambda: defaultdict(list))
    for row in lines(f"{d}/syllables.tsv")[1:]:
        r, g, part, s = row.split("\t")
        syl[(RACES_EN[r], 0 if g == "M" else 1)][part].append(s)
    current = {}
    for row in lines(f"{d}/../in/roster-names-live.tsv"):
        o, g, name, *_ = row.split("\t")
        current[g] = name
    taken = {l.strip().lower() for l in lines(f"{d}/taken.txt")}
    keep = {l.strip().lower() for l in lines(f"{d}/keep-all.txt")}
    block = {l.strip().lower() for l in lines(f"{d}/blocklist.txt")}
    npc_last = defaultdict(list)
    for row in lines(f"{d}/npc-surnames.tsv")[1:]:
        r, s, *_ = row.split("\t")
        if s.lower() not in SURNAME_STOP and len(s) >= 4:
            npc_last[int(r)].append(s)
    origins = defaultdict(list)
    for row in lines(f"{d}/origins-clean.tsv")[1:]:
        r, o, *_ = row.split("\t")
        origins[int(r)].append(o)

    rows = sorted(csv.DictReader(open(plan, newline="", encoding="utf-8")), key=lambda r: int(r["ordinal"]))
    used_first, used_last = set(), set()
    for r in rows:
        r["_old"] = current.get(r["guid"], "") if int(r["ordinal"]) <= 180 else ""
        r["_keep"] = bool(r["_old"]) and r["_old"].lower() in keep and ok(r["_old"]) and r["_old"].lower() not in block
        if r["_keep"]:
            used_first.add(r["_old"].lower())

    def candidates(race, gender):
        listed = sorted(first.get((race, gender), []), key=lambda n: h("first", race, gender, n))
        yield from listed
        parts = syl[(race, gender)]
        combos = {a + c for a in parts["start"] for c in parts["end"]}
        combos |= {a + b + c for a in parts["start"] for b in parts["middle"] for c in parts["end"]}
        yield from sorted((n for n in combos if not CLUMSY.search(n.lower())), key=lambda n: h("syl", race, gender, n))

    def syl_last(race):
        # last resort for small races (trolls): surnames from the race syllables, not used as first names
        out = set()
        for g in (0, 1):
            p = syl[(race, g)]
            out |= {a + c for a in p["start"] for c in p["end"]}
        return sorted(n for n in out if ok(n) and not CLUMSY.search(n.lower()) and n.lower() not in used_first and n.lower() not in block)
    out, stats = [], defaultdict(int)
    for r in rows:
        race, cls, gender, o = int(r["race"]), int(r["class"]), int(r["gender"]), int(r["ordinal"])
        if r["_keep"]:
            fn, status = r["_old"], "KEEP"
        else:
            fn = next((n for n in candidates(race, gender) if ok(n) and n.lower() not in used_first
                       and n.lower() not in block and (n.lower() not in taken or n.lower() == r["_old"].lower())), "")
            status = "NEW" if fn else "NEED_MORE"
            if fn:
                used_first.add(fn.lower())
        src_order = ["origin", "npc", "ob50", "syllable"] if int(h("origin?", r["guid"], o)[:8], 16) / 0xFFFFFFFF < ORIGIN_SHARE \
            else ["npc", "ob50", "origin", "syllable"]
        pools = {"origin": origins[race], "npc": npc_last[race], "ob50": ob50_last[race], "syllable": syl_last(race)}
        surname, src = "", ""
        for k in src_order:
            surname = next((s for s in sorted(pools[k], key=lambda s: h("last", race, s)) if s.lower() not in used_last), "")
            if surname:
                src = k
                break
        if surname:
            used_last.add(surname.lower())
        stats[src or "none"] += 1
        stats[status] += 1
        out.append((o, r["guid"], RACE_NAME[race], CLASS.get(cls, cls), "f" if gender else "m", r["role"],
                    r["_old"], fn, surname, src, status))
    print("ordinal\tguid\trace\tclass\tgender\trole\tcurrent_name\tfirst_name\tsurname_addon\tsurname_source\tstatus")
    for row in out:
        print("\t".join(map(str, row)))
    print("# " + " ".join(f"{k}={v}" for k, v in sorted(stats.items())), file=sys.stderr)


if __name__ == "__main__":
    main()
