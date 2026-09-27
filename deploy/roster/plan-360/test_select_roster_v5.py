#!/usr/bin/env python3
"""Tests for select_roster_v5.py on the real 154 base and synthetic pools (stdlib only).

    python3 -m unittest test_select_roster_v5.py
"""
import contextlib
import csv
import io
import os
import re
import tempfile
import unittest
from collections import Counter

import select_roster_v5 as gen

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.join(HERE, "..", "plan-154", "v4-154-roster-plan.csv")
CATALOG = os.path.join(HERE, "race-class-catalog.tsv")
SPECS = os.path.join(HERE, "spec-roles.tsv")
SPEC_INDEX = os.path.join(HERE, "..", "respec", "premade-spec-index.tsv")
TAKEN = [os.path.join(HERE, "..", "expand-272", "new-136-names.tsv"),
         os.path.join(HERE, "..", "plan-154", "new-18-names.tsv")]
NEW_PAIRS = {(2, 8), (3, 8), (3, 9), (8, 9), (5, 3), (7, 3), (6, 5), (3, 7), (5, 2)}


def catalog():
    return {(int(r), int(c)) for r, c, *_ in gen.read_tsv(CATALOG)}


def base_rows():
    with open(BASE, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


class Run:
    """Default: wave 1 of the owner decision (180 = 10/20/60 per faction, cap 4, REPLACE)."""

    def __init__(self, tmp, target=180, per_faction="10,20,60", cap=4, replace=True, pool=None, extra=()):
        self.tmp = tmp
        self.demand = os.path.join(tmp, "demand.tsv")
        self.out = os.path.join(tmp, "plan.csv")
        self.names = os.path.join(tmp, "names.tsv")
        self.replace = os.path.join(tmp, "replace.tsv")
        argv = ["--base", BASE, "--catalog", CATALOG, "--specs", SPECS, "--target", str(target),
                "--per-faction", per_faction, "--cap", str(cap),
                "--demand", self.demand, "--summary-out", os.path.join(tmp, "summary.md")]
        if replace:
            argv += ["--replace-excess"]
        if pool:
            argv += ["--pool", pool, "--out", self.out, "--names-out", self.names, "--replace-out", self.replace]
            for t in TAKEN:
                argv += ["--taken-names", t]
        argv += list(extra)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            gen.main(argv)
        self.stdout = buf.getvalue()

    def rows(self):
        with open(self.out, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))


def write_pool(tmp, per_gender=12, drop=(), only_male=()):
    path = os.path.join(tmp, "pool.tsv")
    guid = 900000
    with open(path, "w", encoding="utf-8") as f:
        # a base GUID must never be picked again
        f.write("50\t7\tLatchigedap\t6\t11\t0\t12\n")
        for race, cls in sorted(catalog()):
            if (race, cls) in drop:
                continue
            for gender in (0, 1):
                if gender == 1 and (race, cls) in only_male:
                    continue
                for _ in range(per_gender):
                    guid += 1
                    f.write(f"{guid}\t{guid // 9}\tPool{guid}\t{race}\t{cls}\t{gender}\t1\n")
    return path


class GeneratorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def assert_hard_rules(self, rows, per_faction, cap):
        half = sum(per_faction)
        for races in (gen.ALLIANCE, gen.HORDE):
            mine = [r for r in rows if int(r["race"]) in races]
            self.assertEqual(len(mine), half)
            self.assertEqual(Counter(r["role"] for r in mine), Counter(dict(zip(gen.ROLES, per_faction))))
            counts = Counter(int(r["race"]) for r in mine)
            self.assertLessEqual(max(counts.values()) - min(counts.values()), 1, counts)
        specs = {(int(c), p): role for c, p, role in gen.read_tsv(SPECS)}
        base_cells = Counter((r["race"], r["class"], r["role"]) for r in base_rows())
        for (race, cls, role), n in Counter((r["race"], r["class"], r["role"]) for r in rows).items():
            self.assertLessEqual(n, max(cap, base_cells[(race, cls, role)]), (race, cls, role))
        for r in rows:
            self.assertIn((int(r["race"]), int(r["class"])), catalog())
            self.assertEqual(specs[(int(r["class"]), r["talent_path"])], r["role"])
        self.assertEqual(len({r["guid"] for r in rows}), len(rows))

    def test_wave1_180_exact_races_with_replace(self):
        run = Run(self.tmp, pool=write_pool(self.tmp))
        rows = run.rows()
        self.assertEqual(len(rows), 180)
        self.assert_hard_rules(rows, (10, 20, 60), 4)
        for races in (gen.ALLIANCE, gen.HORDE):
            self.assertEqual(set(Counter(int(r["race"]) for r in rows if int(r["race"]) in races).values()), {18})
        base = base_rows()
        repl = gen.read_tsv(run.replace)
        self.assertEqual(len(repl), 4, "22 humans -> 18")
        for ordinal, old, new in repl:
            b = base[int(ordinal) - 1]
            self.assertEqual((b["guid"], b["race"]), (old, "1"))
            self.assertEqual(rows[int(ordinal) - 1]["role"], b["role"], "a replacement keeps the role")
            self.assertNotEqual(old, new)
        changed = {int(o) for o, *_ in repl} | set(range(155, 181))
        for i, (a, b) in enumerate(zip(base, rows[:154]), start=1):
            if i not in changed:
                self.assertEqual(a, b, f"ordinal {i} must stay unchanged")
        self.assertIn("CHANGED_ORDINALS=" + ",".join(map(str, sorted(changed))), run.stdout)
        self.assertEqual(len(gen.read_tsv(run.names)), 30)

    def test_replace_prefers_low_level(self):
        humans = [r for r in base_rows() if r["race"] == "1"]
        first = Run(self.tmp, pool=write_pool(self.tmp))
        picked = {o for o, *_ in gen.read_tsv(first.replace)}
        levels = os.path.join(self.tmp, "levels.tsv")
        with open(levels, "w", encoding="utf-8") as f:
            for r in humans:
                f.write(f"{r['guid']}\t{60 if r['ordinal'] in picked else 2}\n")
        second = Run(self.tmp, pool=write_pool(self.tmp), extra=["--levels", levels])
        self.assertFalse(picked & {o for o, *_ in gen.read_tsv(second.replace)}, "level 60 bots are kept")

    def test_without_replace_races_only_fill_up(self):
        run = Run(self.tmp, replace=False, pool=write_pool(self.tmp))
        rows = run.rows()
        self.assertEqual(rows[:154], base_rows(), "prefix unchanged")
        alliance = Counter(int(r["race"]) for r in rows if int(r["race"]) in gen.ALLIANCE)
        self.assertEqual(alliance[1], 22)
        self.assertEqual(sorted(v for k, v in alliance.items() if k != 1), [17, 17, 17, 17])

    def test_final_360_tank_classes_and_cap(self):
        run = Run(self.tmp, target=360, per_faction="20,40,120", cap=7, pool=write_pool(self.tmp, per_gender=20))
        rows = run.rows()
        self.assert_hard_rules(rows, (20, 40, 120), 7)
        for races in (gen.ALLIANCE, gen.HORDE):
            have = Counter(int(r["class"]) for r in base_rows() if int(r["race"]) in races and r["role"] == "TANK")
            tank_cls = {int(c) for c, _, role in gen.read_tsv(SPECS) if role == "TANK"}
            classes = sorted({c for c in tank_cls if any((r, c) in catalog() for r in races)})
            self.assertEqual(len(classes), 5, "owner: five tank classes per faction")
            want = gen.water_fill(have, 20 - sum(have.values()), classes)
            tanks = Counter(int(r["class"]) for r in rows if int(r["race"]) in races and r["role"] == "TANK")
            self.assertEqual(dict(tanks), want, "tank classes fill up evenly, nobody shrinks")
        new = {(int(r["race"]), int(r["class"])) for r in rows[154:]}
        self.assertEqual(NEW_PAIRS - new, set(), "every new race/class pair gets bots")

    def test_respec_tanks_exact_share(self):
        respec = os.path.join(self.tmp, "respec.tsv")
        run = Run(self.tmp, target=360, per_faction="20,40,120", cap=7, pool=write_pool(self.tmp, per_gender=20),
                  extra=["--respec-tanks", "--respec-out", respec])
        rows = run.rows()
        self.assert_hard_rules(rows, (20, 40, 120), 7)
        for races in (gen.ALLIANCE, gen.HORDE):
            tanks = Counter(r["class"] for r in rows if int(r["race"]) in races and r["role"] == "TANK")
            self.assertEqual(set(tanks.values()), {4}, "owner: 5 tank classes x 20 % of 20")
        base = base_rows()
        moves = gen.read_tsv(respec)
        self.assertTrue(moves)
        for ordinal, guid, old, new in moves:
            b, r = base[int(ordinal) - 1], rows[int(ordinal) - 1]
            self.assertEqual((b["guid"], b["role"], b["talent_path"]), (guid, "TANK", old))
            self.assertEqual((r["guid"], r["class"], r["role"], r["talent_path"]), (guid, b["class"], "DPS", new))
            self.assertEqual(r["profession_pair"], b["profession_pair"])
        lines = run.stdout.splitlines()
        changed = next(l for l in lines if l.startswith("CHANGED_ORDINALS=")).split("=")[1].split(",")
        a6 = next(l for l in lines if l.startswith("A6_ORDINALS=")).split("=")[1].split(",")
        self.assertFalse({o for o, *_ in moves} & set(changed), "a respec is no L1 reset")
        self.assertTrue({o for o, *_ in moves} <= set(a6), "A6 applies the respec")

    def test_healers_follow_healer_classes(self):
        run = Run(self.tmp, target=360, per_faction="20,40,120", cap=7, pool=write_pool(self.tmp, per_gender=20))
        rows = run.rows()
        orc = sum(1 for r in rows if r["race"] == "2" and r["role"] == "HEALER")
        tauren = sum(1 for r in rows if r["race"] == "6" and r["role"] == "HEALER")
        self.assertLessEqual(orc, 7, "orcs have one healer class")
        self.assertGreater(tauren, orc)

    def test_catalog_sources_live_needs_no_new_pairs(self):
        # wave 1 without new pairs is only possible without the REPLACE (gnome DPS cells hit the cap)
        run = Run(self.tmp, replace=False, pool=write_pool(self.tmp, drop=NEW_PAIRS), extra=["--catalog-sources", "live"])
        self.assertFalse({(int(r["race"]), int(r["class"])) for r in run.rows()} & NEW_PAIRS)

    def test_cap_too_small_stops(self):
        with self.assertRaisesRegex(SystemExit, "cannot all be met"):
            Run(self.tmp, cap=2)

    def test_summary_capacity(self):
        Run(self.tmp, target=360, per_faction="20,40,120", cap=7)
        with open(os.path.join(self.tmp, "summary.md"), encoding="utf-8") as f:
            text = f.read()
        self.assertEqual(text.count("| raid 40 | 4/12/24 | 3 | 8/4/48 |"), 2)
        self.assertEqual(text.count("| dungeon 5 | 1/1/3 | 20 |"), 2)

    def test_names(self):
        run = Run(self.tmp, pool=write_pool(self.tmp))
        taken = {row[-1].lower() for t in TAKEN for row in gen.read_tsv(t)}
        names = [row[-1] for row in gen.read_tsv(run.names)]
        self.assertEqual(len({n.lower() for n in names}), len(names))
        for n in names:
            self.assertRegex(n, r"^[A-Z][a-z]{1,11}$")
            self.assertIsNone(re.search(r"(.)\1\1", n))
            self.assertNotIn(n.lower(), taken)

    def test_deterministic(self):
        pool = write_pool(self.tmp)
        a = Run(self.tmp, pool=pool)
        first = (gen.sha256(a.out), gen.sha256(a.names), gen.sha256(a.demand), gen.sha256(a.replace))
        b = Run(self.tmp, pool=pool)
        self.assertEqual(first, (gen.sha256(b.out), gen.sha256(b.names), gen.sha256(b.demand), gen.sha256(b.replace)))

    def test_demand_without_pool_asks_factory(self):
        run = Run(self.tmp)
        rows = gen.read_tsv(run.demand)
        self.assertTrue(all(int(r[8]) > 0 for r in rows))
        self.assertEqual(sum(int(r[2]) + int(r[3]) for r in rows), 30)

    def test_demand_with_full_pool_needs_no_factory(self):
        run = Run(self.tmp, pool=write_pool(self.tmp))
        self.assertTrue(all(int(r[8]) == 0 for r in gen.read_tsv(run.demand)))

    def test_gender_fallback(self):
        run = Run(self.tmp, pool=write_pool(self.tmp, only_male=NEW_PAIRS))
        self.assertEqual(len(run.rows()), 180)

    def test_missing_pair_stops(self):
        with self.assertRaisesRegex(SystemExit, "run the factory first"):
            Run(self.tmp, target=360, per_faction="20,40,120", cap=7, pool=write_pool(self.tmp, drop={(6, 5)}))

    def test_per_faction_must_add_up(self):
        with self.assertRaisesRegex(SystemExit, "does not add up"):
            Run(self.tmp, per_faction="10,20,50")

    def test_spec_paths_known_to_a6(self):
        index = {(int(c), p) for c, _, p in gen.read_tsv(SPEC_INDEX)}
        for c, p, _ in gen.read_tsv(SPECS):
            self.assertIn((int(c), p), index, "A6 would abort on an unknown talent path")


if __name__ == "__main__":
    unittest.main()
