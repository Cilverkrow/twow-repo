"""Unit tests on synthetic data: MPQ tables, raw DBC, dbdiff, WDB records, map and archive helpers."""

import struct
import tempfile
import unittest
from pathlib import Path

from synth import wdb_file, write_mpq, write_wdbc

from clientinventory import archives, dbcraw, dbdiff, maps, mpqmini, wdb

BS = chr(92)


class MpqTest(unittest.TestCase):
    def test_known_table_key_hashes(self):
        self.assertEqual(mpqmini.hash_string("(hash table)", 3), 0xC3AF3770)
        self.assertEqual(mpqmini.hash_string("(block table)", 3), 0xEC83B3A3)

    def test_slash_and_case_are_the_same_name(self):
        self.assertEqual(mpqmini.hash_string("World/Maps/A.adt", 1), mpqmini.hash_string("WORLD" + BS + "MAPS" + BS + "a.ADT", 1))

    def test_has_size_and_delete_marker(self):
        with tempfile.TemporaryDirectory() as d:
            p = write_mpq(Path(d) / "a.mpq", {"DBFilesClient" + BS + "Map.dbc": 123, "x.txt": 0}, deleted=["gone.txt"])
            m = mpqmini.open_mpq(p)
            self.assertTrue(m.has("dbfilesclient/map.dbc"))
            self.assertEqual(m.size_of("DBFilesClient" + BS + "Map.dbc"), (123, 123))
            self.assertEqual(m.size_of("x.txt"), (0, 0))
            self.assertFalse(m.has("nothere.txt"))
            self.assertIsNone(m.size_of("nothere.txt"))
            self.assertTrue(m.is_deleted("gone.txt"))
            self.assertFalse(m.has("gone.txt"))
            self.assertEqual(m.files, 2)

    def test_rejects_other_files(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "bad.mpq"
            p.write_bytes(b"not an archive" * 4)
            with self.assertRaises(ValueError):
                mpqmini.open_mpq(p)


class RawDbcTest(unittest.TestCase):
    def test_roundtrip_and_helpers(self):
        with tempfile.TemporaryDirectory() as d:
            strings = b"\0hello\0"
            p = write_wdbc(Path(d) / "T.dbc", [(1, 1, 0xFFFFFFFF, struct.unpack("<I", struct.pack("<f", 1.5))[0])], strings)
            t = dbcraw.read_raw(p)
            self.assertEqual((t.name, len(t.rows), t.fields), ("T", 1, 4))
            self.assertEqual(t.string(1), "hello")
            self.assertEqual(t.signed(t.rows[0][2]), -1)
            self.assertEqual(t.as_float(t.rows[0][3]), 1.5)

    def test_damaged_file_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            p = write_wdbc(Path(d) / "T.dbc", [(1, 2)])
            p.write_bytes(p.read_bytes()[:-1])
            with self.assertRaises(ValueError):
                dbcraw.read_raw(p)


class DbDiffTest(unittest.TestCase):
    spec = dbdiff.Spec("t", "T", "t", "ID", "entry", [dbdiff.Pair("v", "V", "v"), dbdiff.Pair("f", "F", "f", "float"), dbdiff.Pair("s", "S", "s", "str")])

    def test_only_sides_and_diffs(self):
        dbc = [{"ID": 1, "V": 5, "F": 1.001, "S": "A"}, {"ID": 2, "V": 6, "F": 2.0, "S": "b"}, {"ID": 3, "V": 0, "F": 0, "S": ""}]
        db = [{"entry": "1", "v": "5", "f": "1.0", "s": "a"}, {"entry": "2", "v": "7", "f": "2.0", "s": "b"}, {"entry": "4", "v": "1", "f": "0", "s": ""}]
        r = dbdiff.compare(self.spec, dbc, db)
        self.assertEqual((r.dbc_rows, r.db_rows, r.both), (3, 3, 2))
        self.assertEqual(r.only_dbc, [3])
        self.assertEqual(r.only_db, [4])
        self.assertEqual(r.diffs["v"], [(2, 6, 7)])
        self.assertEqual(r.diffs["f"], [])  # 1.001 and 1.0 are the same at two decimals
        self.assertEqual(r.diffs["s"], [])  # case-insensitive

    def test_int32_and_uint32_are_the_same_bits(self):
        dbc = [{"ID": 1, "V": -1001, "F": 0, "S": ""}]
        db = [{"entry": "1", "v": str(4294967295 - 1000), "f": "0", "s": ""}]
        self.assertEqual(dbdiff.compare(self.spec, dbc, db).diffs["v"], [])

    def test_empty_and_null_cells(self):
        dbc = [{"ID": 1, "V": 0, "F": 0, "S": ""}]
        db = [{"entry": "1", "v": None, "f": "", "s": None}]
        r = dbdiff.compare(self.spec, dbc, db)
        self.assertEqual(r.diffs["v"], [(1, 0, None)])  # a NULL is not 0

    def test_raw_rows_adapter(self):
        with tempfile.TemporaryDirectory() as d:
            p = write_wdbc(Path(d) / "X.dbc", [(7, 0, 1)], b"\0")
            rows = dbdiff.raw_rows(p, {"id": ("u", 0), "flag": ("i", 1)})
            self.assertEqual(rows, [{"id": 7, "flag": 0}])


class WdbTest(unittest.TestCase):
    def test_records_stop_at_zero_entry_and_damage(self):
        data = wdb_file([(5, b"abc"), (6, b"de")])
        self.assertEqual(list(wdb.records(data)), [(5, b"abc"), (6, b"de")])
        self.assertEqual(list(wdb.records(data[:-8] + struct.pack("<II", 9, 99))), [(5, b"abc"), (6, b"de")])  # size beyond the file

    def test_cstrings(self):
        self.assertEqual(wdb.cstrings(b"a\0bb\0c", 0, 3), (["a", "bb"], 6))

    def test_parse_item_and_gameobject(self):
        item = struct.pack("<II", 2, 7) + b"Sword\0\0\0\0" + struct.pack("<II", 1234, 3)
        self.assertEqual(wdb.parse_item(9, item)["name"], "Sword")
        self.assertEqual(wdb.parse_item(9, item)["display"], 1234)
        go = struct.pack("<II", 3, 99) + b"Chest\0\0\0\0"
        self.assertEqual(wdb.parse_gameobject(4, go), {"entry": 4, "name": "Chest", "type": 3, "display": 99})

    def test_load_reads_header_and_counts(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "itemcache.wdb"
            item = struct.pack("<II", 0, 0) + b"A\0\0\0\0" + struct.pack("<II", 1, 1)
            p.write_bytes(wdb_file([(1, item)]))
            hdr, count, rows = wdb.load(p)
            self.assertEqual((hdr.build, count, rows[0]["entry"]), (5875, 1, 1))


class MapsTest(unittest.TestCase):
    def listing(self):
        return {
            "a.mpq": [f"World{BS}Maps{BS}Kalimdor{BS}Kalimdor.wdt", f"World{BS}Maps{BS}Kalimdor{BS}Kalimdor_1_2.adt", f"World{BS}Maps{BS}Kalimdor{BS}Kalimdor_3_4.adt"],
            "b.mpq": [f"World{BS}Maps{BS}Kalimdor{BS}Kalimdor_3_4.adt"],
        }

    def test_client_maps_and_effective_filter(self):
        cm = maps.client_maps(self.listing())
        self.assertEqual(sorted(cm["kalimdor"]["tiles"]), [(1, 2), (3, 4)])
        self.assertEqual(cm["kalimdor"]["tiles"][(3, 4)], ["a.mpq", "b.mpq"])
        self.assertEqual(cm["kalimdor"]["wdt"], ["a.mpq"])
        eff = {f"world{BS}maps{BS}kalimdor{BS}kalimdor_3_4.adt": ("b.mpq", 0)}
        self.assertEqual(sorted(maps.client_maps(self.listing(), eff)["kalimdor"]["tiles"]), [(1, 2)])

    def test_server_tiles_and_orientation(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for sub in ("maps", "vmaps", "mmaps"):
                (root / sub).mkdir()
            (root / "maps" / "0010203.map").write_bytes(b"")
            (root / "vmaps" / "001_02_03.vmtile").write_bytes(b"")
            (root / "vmaps" / "001.vmtree").write_bytes(b"")
            (root / "mmaps" / "0010203.mmtile").write_bytes(b"")
            (root / "mmaps" / "001.mmap").write_bytes(b"")
            st = maps.server_tiles(root)
            # 0010203.map: map id = first three digits (001), tile = next two pairs (02, 03)
            self.assertEqual(st[1], {"maps": {(2, 3)}, "vmaps": {(2, 3)}, "mmaps": {(2, 3)}, "vmtree": True, "mmap": True})
        self.assertEqual(maps.best_orientation({(1, 2)}, {(2, 1)}), ("swapped", 1))
        self.assertEqual(maps.best_orientation({(1, 2)}, {(1, 2)}), ("same", 1))

    def test_tile_diffs_report_both_sides(self):
        cm = {"x": {"tiles": {(1, 1): ["a"], (2, 2): ["a"]}, "wdt": []}}
        rows = maps.tile_diffs([{"ID": 9, "Directory": "X"}], cm, {9: {"maps": {(2, 2), (5, 5)}}})
        sides = sorted((r[2], r[3], r[4]) for r in rows)
        self.assertEqual(sides, [("client-only", 1, 1), ("server-only", 5, 5)])

    def test_spawns_without_terrain(self):
        cm = {"azeroth": {"tiles": {(30, 12): ["p"]}, "wdt": []}}
        spawns = [{"map": "0", "tx_from_y": "30", "ty_from_x": "12", "n": "4"}, {"map": "0", "tx_from_y": "31", "ty_from_x": "12", "n": "9"}, {"map": "5", "tx_from_y": "1", "ty_from_x": "1", "n": "1"}]
        self.assertEqual(maps.spawns_without_terrain(cm, spawns, {0: "Azeroth"}, "creature"), [["creature", 0, "Azeroth", 31, 12, 9]])


class ArchivesTest(unittest.TestCase):
    def test_effective_map_files_last_archive_wins_and_size_zero_means_emptied(self):
        name = f"World{BS}Maps{BS}Azeroth{BS}Azeroth_1_1.adt"
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            write_mpq(root / "a.mpq", {name: 500})
            write_mpq(root / "b.mpq", {name: 0})
            eff = archives.effective_map_files(root, {"a.mpq": [name], "b.mpq": [name]})
            self.assertEqual(eff[name.lower()], ("b.mpq", 0))

    def test_archive_facts_listing_completeness(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            write_mpq(root / "a.mpq", {"one.txt": 1, "two.txt": 2, "(listfile)": 9, "(attributes)": 9})
            rows = archives.archive_facts(root, {"a.mpq": ["one.txt", "two.txt"]})
            self.assertEqual(rows[0][2:5], [4, 2, 0])  # blocks, listed names, missing = blocks - listed - 2

    def test_override_chains_are_case_insensitive(self):
        ch = archives.override_chains({"a": ["X\\Y.dbc"], "b": ["x\\y.DBC"]})
        self.assertEqual(ch["x\\y.dbc"], ["a", "b"])


if __name__ == "__main__":
    unittest.main()
