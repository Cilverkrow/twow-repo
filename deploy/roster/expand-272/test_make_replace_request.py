#!/usr/bin/env python3
"""Tests for make_replace_request.py (stdlib unittest, no database).

The expected bytes are written out by hand from the core's SerializeAdminRequest()
(twow-core PersistentActiveRoster.cpp): field order, "null" for the unused rollback
version, replace rows sorted by old GUID and numbered from 1.

    python3 -m unittest test_make_replace_request.py
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import make_replace_request as mrr  # noqa: E402

OP = "0f8fad5b-d9cb-469f-a165-70867728950e"


class ReplaceRequestTest(unittest.TestCase):
    def test_canonical_bytes(self):
        data = mrr.build([(140, 900003), (89, 900001)], 4, 154, OP, "ob40", "swap")
        expected = (
            "ssc-rndbot-admin-request-v1\n"
            "schema_version=1\n"
            f"operation_id={OP}\n"
            "operation_type=REPLACE\n"
            "expected_current_version_id=4\n"
            "actor_utf8_b64url=b2I0MA\n"
            "reason_utf8_b64url=c3dhcA\n"
            "requested_target_count=154\n"
            "add_count=0\n"
            "remove_count=0\n"
            "replace_count=2\n"
            "replace\t0000000001\t0000000089\t0000900001\n"
            "replace\t0000000002\t0000000140\t0000900003\n"
            "rollback_version_id=null\n"
        ).encode("utf-8")
        self.assertEqual(data, expected)

    def test_rejects_duplicates_and_overlap(self):
        with self.assertRaises(ValueError):
            mrr.build([(1, 5), (1, 6)], 4, 154, OP, "a", "r")
        with self.assertRaises(ValueError):
            mrr.build([(1, 5), (2, 5)], 4, 154, OP, "a", "r")
        with self.assertRaises(ValueError):
            mrr.build([(1, 2), (2, 3)], 4, 154, OP, "a", "r")

    def test_rejects_bad_ids_and_empty(self):
        with self.assertRaises(ValueError):
            mrr.build([(1, 2)], 4, 154, "not-a-uuid", "a", "r")
        with self.assertRaises(ValueError):
            mrr.build([], 4, 154, OP, "a", "r")
        with self.assertRaises(ValueError):
            mrr.build([(1, 2)], 4, 154, OP, "", "r")


if __name__ == "__main__":
    unittest.main()
