import tempfile
import unittest
from pathlib import Path

from synth import binding, pack

from clientpatch.delta import Touched, apply_all, apply_file
from clientpatch.diff import dbcdiff, undeclared
from clientpatch.errors import DeltaError
from clientpatch.sqlsrc import SqlData, Source
from clientpatch.wdbc import Table

HEADER = "op,key,field,value,note\n"


def talent_table():
    b = binding("Talent")
    return Table.from_bytes(pack(b, [
        {"ID": 100, "TabID": 261, "TierID": 0, "ColumnIndex": 1, "SpellRank[0]": 16039},
        {"ID": 101, "TabID": 261, "TierID": 1, "ColumnIndex": 2},
    ]), b)


class Deltas(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / "Talent").mkdir()

    def write(self, name, body, dbc="Talent"):
        p = self.tmp / dbc / name
        p.write_text(HEADER + body, encoding="utf-8")
        return p

    def test_set_insert_copy_and_ordering(self):
        self.write("0001_first.csv",
                   "# comment line\n"
                   "set,100,SpellRank[1],90100,shaman R2 (#357)\n"
                   "insert,102,,copy:101,new slot\n")
        self.write("0002_second.csv",
                   "set,102,TierID,6,\n"
                   "set,102,SpellRank[0],0x15FC5,hex works\n")
        t = talent_table()
        base = talent_table()
        touched, files = apply_all(t, self.tmp, None)
        self.assertEqual([f.name for f in files], ["0001_first.csv", "0002_second.csv"])
        self.assertEqual(t.get((100,), "SpellRank[1]"), 90100)
        self.assertEqual(t.get((102,), "TierID"), 6)
        self.assertEqual(t.get((102,), "ColumnIndex"), 2)  # copied from 101
        self.assertEqual(t.get((102,), "SpellRank[0]"), 90053)
        self.assertEqual(undeclared(dbcdiff(base, t), touched), [])

    def test_undeclared_difference_is_caught(self):
        t, base = talent_table(), talent_table()
        t.set((101,), "Flags", 1)  # a change no delta declared
        self.assertEqual(len(undeclared(dbcdiff(base, t), Touched())), 1)

    def test_errors_name_file_and_line(self):
        p = self.write("0001_bad.csv", "set,100,NoSuchColumn,1,\n")
        with self.assertRaisesRegex(DeltaError, r"0001_bad\.csv:2: .*unknown column"):
            apply_file(talent_table(), p, None, Touched())
        p = self.write("0002_bad.csv", "set,999,TierID,1,\n")
        with self.assertRaisesRegex(DeltaError, "no row with key"):
            apply_file(talent_table(), p, None, Touched())
        p = self.write("0003_bad.csv", "delete,100,,,\n")
        with self.assertRaisesRegex(DeltaError, "unknown op"):
            apply_file(talent_table(), p, None, Touched())
        p = self.write("0004_bad.csv", "set,100,ID,5,\n")
        with self.assertRaisesRegex(DeltaError, "key columns"):
            apply_file(talent_table(), p, None, Touched())

    def test_bad_header_and_file_name(self):
        (self.tmp / "Talent" / "0001_x.csv").write_text("a,b\n", encoding="utf-8")
        with self.assertRaisesRegex(DeltaError, "header must be exactly"):
            apply_all(talent_table(), self.tmp, None)
        (self.tmp / "Talent" / "0001_x.csv").unlink()
        (self.tmp / "Talent" / "first.csv").write_text(HEADER, encoding="utf-8")
        with self.assertRaisesRegex(DeltaError, "NNNN_description"):
            apply_all(talent_table(), self.tmp, None)

    def test_text_escapes_and_composite_key(self):
        (self.tmp / "CharBaseInfo").mkdir()
        b = binding("CharBaseInfo")
        t = Table.from_bytes(pack(b, [{"RaceID": 1, "ClassID": 1}]), b)
        self.write("0001_dwarf_shaman.csv", "insert,3:7,,,#379\n", dbc="CharBaseInfo")
        touched, _ = apply_all(t, self.tmp, None)
        self.assertTrue(t.has_key((3, 7)))
        self.assertIn((3, 7), touched.inserted)

        (self.tmp / "SpellIcon").mkdir()
        b = binding("SpellIcon")
        t = Table.from_bytes(pack(b, [{"ID": 1, "TextureFilename": "x"}]), b)
        self.write("0001_t.csv", 'set,1,TextureFilename,"a\\nb, c",\n', dbc="SpellIcon")
        apply_all(t, self.tmp, None)
        self.assertEqual(t.get((1,), "TextureFilename"), "a\nb, c")

    def test_sql_values_come_from_the_server_export(self):
        sql_dir = self.tmp / "sql"
        sql_dir.mkdir()
        (sql_dir / "spell_template.tsv").write_text(
            "entry\teffectBasePoints1\n2645\t19\n", encoding="utf-8")
        sql = SqlData({"spell_template": Source("spell_template", "SELECT 1", "entry")}, sql_dir)
        (self.tmp / "Spell").mkdir()
        b = binding("Spell")
        t = Table.from_bytes(pack(b, [{"ID": 2645}]), b)
        self.write("0001_ghost_wolf.csv",
                   "set,2645,EffectBasePoints[0],sql:spell_template.effectBasePoints1,\n",
                   dbc="Spell")
        apply_all(t, self.tmp, sql)
        self.assertEqual(t.get((2645,), "EffectBasePoints[0]"), 19)


if __name__ == "__main__":
    unittest.main()
