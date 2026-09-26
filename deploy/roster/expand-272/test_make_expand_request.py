#!/usr/bin/env python3
"""Tests for make_expand_request.py (stdlib unittest, no database).

The golden file is the canonical request stored with roster version 3 in the live
database (`ai_playerbot_roster_version.canonical_request`, request_sha256
6f0c1971...e88d): the 2 -> 3 expansion that added ordinals 69-136 of the V4 prefix.
Rebuilding it byte for byte from the prefix CSV proves the serialization matches
what the core accepted.

    python3 test_make_expand_request.py
"""
import base64
import hashlib
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import make_expand_request as mer  # noqa: E402

GOLDEN = os.path.join(HERE, "testdata", "v3-expand-request.golden.txt")
PREFIX = os.path.join(HERE, "..", "v4-136-profession-prefix.csv")
PLAN = os.path.join(HERE, "v4-272-roster-plan.csv")
GOLDEN_SHA256 = "6f0c19710e4f19bfea3eb0f600724e5101537dccb49642857f368af130a2e88d"


def field(data, key):
    for line in data.decode("utf-8").split("\n"):
        if line.startswith(key + "="):
            return line.split("=", 1)[1]
    raise KeyError(key)


def unb64(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)).decode("utf-8")


def run(*args):
    return subprocess.run([sys.executable, os.path.join(HERE, "make_expand_request.py"), *args],
                          capture_output=True, text=True)


class GoldenTest(unittest.TestCase):
    def test_golden_file_is_the_stored_request(self):
        with open(GOLDEN, "rb") as f:
            self.assertEqual(hashlib.sha256(f.read()).hexdigest(), GOLDEN_SHA256)

    def test_rebuilds_v3_request_byte_for_byte(self):
        with open(GOLDEN, "rb") as f:
            golden = f.read()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "req.txt")
            r = run("--csv", PREFIX, "--ordinals", "69-136", "--expected-current-version", "2",
                    "--operation-id", field(golden, "operation_id"),
                    "--actor", unb64(field(golden, "actor_utf8_b64url")),
                    "--reason", unb64(field(golden, "reason_utf8_b64url")), "--out", out)
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(out, "rb") as f:
                self.assertEqual(f.read(), golden)
            self.assertIn(f"request_sha256={GOLDEN_SHA256}", r.stdout)


class PlanTest(unittest.TestCase):
    def test_272_request_shape(self):
        if not os.path.exists(PLAN):
            self.skipTest("272 plan not present")
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "req.txt")
            opid = "11111111-2222-4333-8444-555555555555"
            r = run("--csv", PLAN, "--ordinals", "137-272", "--expected-current-version", "3",
                    "--operation-id", opid, "--actor", "ob40-test", "--reason", "test", "--out", out)
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(out, "rb") as f:
                data = f.read()
            self.assertNotIn(b"\r", data)
            self.assertTrue(data.endswith(b"rollback_version_id=null\n"))
            self.assertEqual(field(data, "requested_target_count"), "272")
            self.assertEqual(field(data, "add_count"), "136")
            adds = [l for l in data.decode().split("\n") if l.startswith("add\t")]
            self.assertEqual(len(adds), 136)
            self.assertEqual(adds[0].split("\t")[1], "0000000001")
            self.assertEqual(adds[-1].split("\t")[1], "0000000136")
            # same inputs, same bytes
            out2 = os.path.join(tmp, "req2.txt")
            run("--csv", PLAN, "--ordinals", "137-272", "--expected-current-version", "3",
                "--operation-id", opid, "--actor", "ob40-test", "--reason", "test", "--out", out2)
            with open(out2, "rb") as f:
                self.assertEqual(f.read(), data)


class RejectTest(unittest.TestCase):
    def test_bad_operation_id(self):
        with self.assertRaises(ValueError):
            mer.build([1, 2], 3, 5, "977FBD53-0AF0-4FBF-AA33-954841BFBF8B", "a", "b")
        with self.assertRaises(ValueError):
            mer.build([1, 2], 3, 5, "977fbd53-0af0-1fbf-aa33-954841bfbf8b", "a", "b")

    def test_duplicate_or_zero_guid(self):
        with self.assertRaises(ValueError):
            mer.build([7, 7], 3, 5, "977fbd53-0af0-4fbf-aa33-954841bfbf8b", "a", "b")
        with self.assertRaises(ValueError):
            mer.build([0], 3, 5, "977fbd53-0af0-4fbf-aa33-954841bfbf8b", "a", "b")

    def test_empty_actor(self):
        with self.assertRaises(ValueError):
            mer.build([1], 3, 5, "977fbd53-0af0-4fbf-aa33-954841bfbf8b", "", "b")

    def test_range_beyond_csv(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = run("--csv", PREFIX, "--ordinals", "137-272", "--expected-current-version", "3",
                    "--actor", "a", "--reason", "b", "--out", os.path.join(tmp, "x"))
            self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
