"""facts: ids and tiles as SQL ranges."""

import unittest

from clientinventory import facts


class FactsTest(unittest.TestCase):
    def test_compress_merges_runs_and_ignores_duplicates(self):
        self.assertEqual(facts.compress([5, 1, 2, 3, 3, 9]), [(1, 3), (5, 5), (9, 9)])
        self.assertEqual(facts.compress([]), [])

    def test_predicate(self):
        self.assertEqual(facts.predicate("x", [(1, 3), (5, 5)]), "x BETWEEN 1 AND 3\n OR x = 5")
        self.assertEqual(facts.predicate("x", []), "1 = 0")

    def test_tile_ids_use_x_times_1000(self):
        cm = {"azeroth": {"tiles": {(31, 49): ["a"], (2, 3): ["a"]}, "wdt": []}}
        self.assertEqual(sorted(facts.tile_ids(cm, "Azeroth")), [2003, 31049])
        self.assertEqual(facts.tile_ids(cm, "Nowhere"), [])

    def test_render_is_a_dbcheck_macro_file(self):
        text = facts.render([1, 2, 4], {0: [31049]}, "test", on="2026-10-02")
        self.assertIn("[macro]", text)
        self.assertIn("t.displayId BETWEEN 1 AND 2\n OR t.displayId = 4", text)
        self.assertIn("client_tiles_map0", text)
        self.assertIn("s.tid = 31049", text)
        self.assertIn("date 2026-10-02", text)


if __name__ == "__main__":
    unittest.main()
