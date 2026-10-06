#!/usr/bin/env python3
"""#518: origin names "von <Ort>" per race from AreaTable.dbc (read-only copy) in the English client names
(owner 04.10; the German column is only kept for reference). Places map to races by their zone (lore homeland, OB-40 draft; OB-50 may
refine). Output: race, origin ("von <Ort>"), area id, English name.

    origin_places.py AreaTable.dbc > origins.tsv"""
import struct
import sys

# zone id -> races (lore homelands; 1 human, 2 orc, 3 dwarf, 4 night elf, 5 undead, 6 tauren, 7 gnome,
# 8 troll, 9 goblin, 10 high elf)
ZONES = {
    12: [1], 40: [1], 44: [1], 10: [1], 1519: [1], 45: [1, 10], 267: [1], 36: [1], 15: [1], 33: [9, 8],
    1: [3, 7], 38: [3], 11: [3], 1537: [3, 7], 133: [7],
    141: [4], 148: [4], 331: [4], 357: [4], 493: [4], 1657: [4],
    14: [2, 8], 1637: [2], 17: [2, 6, 9], 406: [6],
    85: [5], 130: [5], 1497: [5], 28: [5, 10], 139: [10],
    215: [6], 1638: [6], 400: [6],
    47: [8],
    440: [9], 618: [9],
}


def main():
    data = open(sys.argv[1], "rb").read()
    magic, nrec, nfield, rsize, ssize = struct.unpack_from("<4s4I", data)
    strings = data[20 + nrec * rsize:]

    def s(off):
        if off <= 0 or off >= len(strings):
            return ""
        return strings[off:strings.index(b"\0", off)].decode("utf-8", "replace")
    recs = [struct.unpack_from(f"<{nfield}I", data, 20 + i * rsize) for i in range(nrec)]
    en_col = de_col = None
    for r in recs:
        for i, v in enumerate(r):
            if s(v) == "Goldshire":
                en_col = i
            if s(v) == "Goldhain":
                de_col = i
        if en_col is not None and de_col is not None:
            break
    if en_col is None or de_col is None:
        sys.exit("name columns not found")
    print("race\torigin\tarea\tname_de")
    seen = set()
    for r in recs:
        area, zone = r[0], r[2] or r[0]
        de, en = s(r[de_col]), clean_en(s(r[en_col]))
        if not en or zone not in ZONES or len(en) > 16 or any(c.isdigit() for c in en):
            continue
        for race in ZONES[zone]:
            key = (race, en)
            if key not in seen:
                seen.add(key)
                print(f"{race}\tof {en}\t{area}\t{de}")  # owner 04.10: English "of <place>"


# owner 04.10: origins in the English client names ("von Goldshire", not "von Goldhain"). Trailing
# geographic nouns go ("Redridge Mountains" -> "Redridge", "Theramore Isle" -> "Theramore"); only
# one-word places remain, no articles and no generic sites (mine, farm, camp, ...).
TRAIL = ("Mountains", "Isle", "Island", "Hills", "Highlands", "Forest", "Valley", "Woods", "Glade", "Village",
         "Keep", "City", "Vale", "Canyon", "Coast", "Plains", "Fields", "Gorge", "Peaks", "Foothills", "Marsh")
GENERIC = {"mine", "farm", "camp", "lake", "bay", "inn", "tower", "graveyard", "cave", "ruins", "hut", "house",
           "post", "outpost", "road", "pass", "bridge", "gate", "falls", "pool", "pond", "shore", "beach", "dock",
           "docks", "crossing", "landing", "grounds", "garden", "gardens", "cemetery", "lighthouse", "unused",
           "den", "lair", "hollow", "cavern", "barrow", "barrows", "tunnel", "quarry", "lodge", "hall", "spring"}


def clean_en(name):
    words = name.split()
    while len(words) > 1 and words[-1] in TRAIL:
        words.pop()
    if len(words) != 1:
        return ""
    w = words[0]
    if w.lower() in GENERIC or w in ("The",) or len(w) < 4 or not w[0].isupper():
        return ""
    return w


if __name__ == "__main__":
    main()
