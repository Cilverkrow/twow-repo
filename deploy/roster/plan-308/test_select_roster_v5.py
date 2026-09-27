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


class Run:
    def __init__(self, tmp, target=308, per_faction="20,40,94", bears=2, pool=None, extra=()):
        self.demand = os.path.join(tmp, "demand.tsv")
        self.out = os.path.join(tmp, "plan.csv")
        self.names = os.path.join(tmp, "names.tsv")
        argv = ["--base", BASE, "--catalog", CATALOG, "--specs", SPECS, "--target", str(target),
                "--per-faction", per_faction, "--bears-per-race-gender", str(bears), "--demand", self.demand]
        if pool:
            argv += ["--pool", pool, "--out", self.out, "--names-out", self.names]
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


def write_pool(tmp, per_gender=4, drop=(), only_male=()):
    path = os.path.join(tmp, "pool.tsv")
    guid = 900000
    with open(path, "w", encoding="utf-8") as f:
        # two base GUIDs must never be picked again
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

    def test_hard_rules_308(self):
        run = Run(self.tmp, pool=write_pool(self.tmp))
        rows = run.rows()
        self.assertEqual(len(rows), 308)
        with open(BASE, encoding="utf-8") as f:
            base = f.read()
        with open(run.out, encoding="utf-8") as f:
            self.assertTrue(f.read().startswith(base), "rows 1-154 must stay byte-identical")
        for fa, races in (("A", gen.ALLIANCE), ("H", gen.HORDE)):
            mine = [r for r in rows if int(r["race"]) in races]
            self.assertEqual(len(mine), 154)
            self.assertEqual(Counter(r["role"] for r in mine), Counter(TANK=20, HEALER=40, DPS=94))
            for race, n in Counter(int(r["race"]) for r in mine).items():
                self.assertIn(n, (30, 31), f"race {race}")
        bears = Counter((r["race"], r["gender"]) for r in rows if r["talent_path"] == "bear")
        self.assertEqual(sorted(bears.values()), [2, 2, 2, 2])
        specs = {(int(c), p): role for c, p, role in gen.read_tsv(SPECS)}
        for r in rows:
            self.assertIn((int(r["race"]), int(r["class"])), catalog())
            self.assertEqual(specs[(int(r["class"]), r["talent_path"])], r["role"])
        new = {(int(r["race"]), int(r["class"])) for r in rows[154:]}
        self.assertEqual(NEW_PAIRS - new, set(), "every new race/class pair gets bots")
        self.assertEqual(sum(Counter(r["profession_pair"] for r in rows).values()), 308)
        self.assertEqual(len({r["guid"] for r in rows}), 308)
        self.assertNotIn("50", {r["guid"] for r in rows[154:]})
        self.assertIn("gender_fallback=0", run.stdout)

    def test_role_share_per_race(self):
        run = Run(self.tmp, pool=write_pool(self.tmp))
        rows = run.rows()
        for race in range(1, 11):
            tanks = sum(1 for r in rows if int(r["race"]) == race and r["role"] == "TANK")
            self.assertGreaterEqual(tanks, 3, f"race {race} tanks")

    def test_names(self):
        run = Run(self.tmp, pool=write_pool(self.tmp))
        taken = {row[-1].lower() for t in TAKEN for row in gen.read_tsv(t)}
        names = [row[-1] for row in gen.read_tsv(run.names)]
        self.assertEqual(len(names), 154)
        self.assertEqual(len({n.lower() for n in names}), 154)
        for n in names:
            self.assertRegex(n, r"^[A-Z][a-z]{1,11}$")
            self.assertIsNone(re.search(r"(.)\1\1", n))
            self.assertNotIn(n.lower(), taken)

    def test_deterministic(self):
        pool = write_pool(self.tmp)
        a = Run(self.tmp, pool=pool)
        first = (gen.sha256(a.out), gen.sha256(a.names), gen.sha256(a.demand))
        b = Run(self.tmp, pool=pool)
        self.assertEqual(first, (gen.sha256(b.out), gen.sha256(b.names), gen.sha256(b.demand)))

    def test_demand_without_pool_asks_factory(self):
        run = Run(self.tmp)
        rows = gen.read_tsv(run.demand)
        self.assertTrue(all(int(r[8]) > 0 for r in rows))
        self.assertEqual(sum(int(r[2]) + int(r[3]) for r in rows), 154)

    def test_demand_with_full_pool_needs_no_factory(self):
        run = Run(self.tmp, pool=write_pool(self.tmp, per_gender=8))
        self.assertTrue(all(int(r[8]) == 0 for r in gen.read_tsv(run.demand)))

    def test_gender_fallback(self):
        run = Run(self.tmp, pool=write_pool(self.tmp, per_gender=8, only_male=NEW_PAIRS))
        self.assertNotIn("gender_fallback=0", run.stdout)
        self.assertEqual(len(run.rows()), 308)

    def test_missing_pair_stops(self):
        with self.assertRaisesRegex(SystemExit, "run the factory first"):
            Run(self.tmp, pool=write_pool(self.tmp, drop={(6, 5)}))

    def test_race_above_target_needs_replace(self):
        # 200 = 20 per race; humans already have 22
        with self.assertRaisesRegex(SystemExit, "only a REPLACE"):
            Run(self.tmp, target=200, per_faction="13,26,61", bears=1)

    def test_per_faction_must_add_up(self):
        with self.assertRaisesRegex(SystemExit, "does not add up"):
            Run(self.tmp, per_faction="20,40,90")

    def test_scales_to_462(self):
        run = Run(self.tmp, target=462, per_faction="30,60,141", bears=3,
                  pool=write_pool(self.tmp, per_gender=12))
        rows = run.rows()
        self.assertEqual(len(rows), 462)
        for races in (gen.ALLIANCE, gen.HORDE):
            for n in Counter(int(r["race"]) for r in rows if int(r["race"]) in races).values():
                self.assertIn(n, (46, 47))

    def test_spec_paths_known_to_a6(self):
        index = {(int(c), p) for c, _, p in gen.read_tsv(SPEC_INDEX)}
        for c, p, _ in gen.read_tsv(SPECS):
            self.assertIn((int(c), p), index, "A6 would abort on an unknown talent path")


if __name__ == "__main__":
    unittest.main()
