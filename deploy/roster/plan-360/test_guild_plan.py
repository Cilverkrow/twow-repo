#!/usr/bin/env python3
"""Tests for guild_plan.py (#518, core#309 PlanFile): role split, healer classes, --rare-spread. stdlib only."""
import csv
import os
import subprocess
import sys
import tempfile
import unittest
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
FIELDS = ["ordinal", "guid", "account", "name", "race", "class", "gender", "talent_path", "role",
          "profession_pair", "selection_reason", "source_candidate_hash"]


def plan(tmp, rows):
    path = os.path.join(tmp, "plan.csv")
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS, lineterminator="\n")
        w.writeheader()
        for i, (race, cls, role) in enumerate(rows, start=1):
            w.writerow({"ordinal": i, "guid": 1000 + i, "account": 1, "name": f"Bot{i}", "race": race, "class": cls,
                        "gender": 1, "talent_path": "x", "role": role, "profession_pair": "x",
                        "selection_reason": "", "source_candidate_hash": ""})
    return path


def run(path, *extra):
    out = subprocess.run([sys.executable, os.path.join(HERE, "guild_plan.py"), path, "--per-guild", "1,2,3", *extra],
                         capture_output=True, text=True, check=True).stdout
    return list(csv.DictReader(out.splitlines(), delimiter="\t"))


# Alliance only (races 1, 3, 4): 3 guilds x (1 tank, 2 healers, 3 DPS); dwarf shaman (3:7) is the rare pair
ROWS = ([("1", "1", "TANK")] * 3
        + [("1", "5", "HEALER")] * 2 + [("3", "5", "HEALER")] * 1 + [("3", "7", "HEALER")] * 3
        + [("3", "7", "DPS")] * 3 + [("1", "8", "DPS")] * 3 + [("4", "3", "DPS")] * 3)


class GuildPlanTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def test_roles_and_healer_classes(self):
        rows = run(plan(self.tmp, ROWS))
        roles = Counter((r["guild"], r["role"]) for r in rows)
        for g in ("A1", "A2", "A3"):
            self.assertEqual((roles[(g, "TANK")], roles[(g, "HEALER")], roles[(g, "DPS")]), (1, 2, 3))
        heal = defaultdict(set)
        for r in rows:
            if r["role"] == "HEALER":
                heal[r["guild"]].add(r["class"])
        self.assertTrue(all("7" in heal[g] for g in ("A1", "A2", "A3")), "every guild gets a shaman healer")

    def test_rare_spread_caps_pairs(self):
        rows = run(plan(self.tmp, ROWS), "--rare-spread")
        per_guild = Counter((r["guild"], r["race"], r["class"]) for r in rows)
        self.assertLessEqual(max(n for (g, race, cls), n in per_guild.items() if (race, cls) == ("3", "7")), 2,
                             "6 dwarf shamans over 3 guilds: at most ceil(6/3) = 2 per guild")
        roles = Counter((r["guild"], r["role"]) for r in rows)
        self.assertEqual(roles[("A1", "DPS")], 3)

    def test_without_flag_unchanged_and_deterministic(self):
        p = plan(self.tmp, ROWS)
        self.assertEqual(run(p), run(p))

    def test_keep_leaves_guilds(self):
        p = plan(self.tmp, ROWS)
        first = run(p)
        keep = os.path.join(self.tmp, "keep.tsv")
        with open(keep, "w", encoding="utf-8") as f:
            f.write("ordinal\tguid\tfaction\tguild\trole\tclass\trace\n")
            for r in first:
                f.write("\t".join(r[k] for k in ("ordinal", "guid", "faction", "guild", "role", "class", "race")) + "\n")
        again = run(p, "--keep", keep, "--rare-spread")
        self.assertEqual([r["guild"] for r in first], [r["guild"] for r in again])


if __name__ == "__main__":
    unittest.main()
