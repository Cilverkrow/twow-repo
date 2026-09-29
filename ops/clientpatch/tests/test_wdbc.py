import struct
import unittest

from synth import BINDINGS, binding, pack, random_rows

from clientpatch.binding import load_bindings
from clientpatch.errors import LayoutError
from clientpatch.wdbc import Table


class RoundTrip(unittest.TestCase):
    def test_every_binding_round_trips_byte_identical(self):
        for name, b in load_bindings(BINDINGS).items():
            with self.subTest(dbc=name):
                data = pack(b, random_rows(b, 7, seed=len(name)))
                self.assertEqual(Table.from_bytes(data, b).to_bytes(), data)

    def test_unshared_string_block_round_trips(self):
        b = binding("SpellIcon")
        rows = [{"ID": 1, "TextureFilename": "a"}, {"ID": 2, "TextureFilename": "a"}]
        data = pack(b, rows, share_strings=False)
        self.assertEqual(Table.from_bytes(data, b).to_bytes(), data)

    def test_binding_sizes_match_core_formats(self):
        # Field counts cross-checked with twow-core DBCfmt.h by gen_bindings.py.
        expected = {"Talent": 21, "TalentTab": 15, "ChrRaces": 29, "ChrClasses": 17,
                    "Spell": 173, "SkillRaceClassInfo": 8, "SpellItemEnchantment": 24,
                    "Map": 42, "AreaTrigger": 10}
        bs = load_bindings(BINDINGS)
        for name, count in expected.items():
            self.assertEqual(bs[name].field_count, count, name)
        self.assertEqual(bs["CharBaseInfo"].record_size, 2)  # two uint8 fields


class Layout(unittest.TestCase):
    def test_wrong_layout_is_a_clear_error(self):
        b = binding("SpellIcon")
        data = bytearray(pack(b, [{"ID": 1, "TextureFilename": "x"}]))
        struct.pack_into("<I", data, 8, 3)  # field_count 3 instead of 2
        with self.assertRaisesRegex(LayoutError, "Wrong client build or wrong binding"):
            Table.from_bytes(bytes(data), b)

    def test_not_a_dbc(self):
        with self.assertRaises(LayoutError):
            Table.from_bytes(b"XXXX" + bytes(16), binding("SpellIcon"))


class Mutation(unittest.TestCase):
    def test_set_changes_only_that_row_and_keeps_old_strings(self):
        b = binding("SpellIcon")
        rows = [{"ID": 1, "TextureFilename": "Interface\\Icons\\A"},
                {"ID": 2, "TextureFilename": "Interface\\Icons\\B"}]
        data = pack(b, rows)
        t = Table.from_bytes(data, b)
        t.set((2,), "TextureFilename", "Interface\\Icons\\C")
        again = Table.from_bytes(t.to_bytes(), b)
        self.assertEqual(again.get((1,), "TextureFilename"), "Interface\\Icons\\A")
        self.assertEqual(again.get((2,), "TextureFilename"), "Interface\\Icons\\C")
        # The old block is kept as a prefix; row 1 is untouched byte for byte.
        new = t.to_bytes()
        self.assertEqual(new[20:28], data[20:28])

    def test_existing_string_is_reused(self):
        b = binding("SpellIcon")
        t = Table.from_bytes(pack(b, [{"ID": 1, "TextureFilename": "same"},
                                      {"ID": 2, "TextureFilename": "other"}]), b)
        size = len(t.to_bytes())
        t.set((2,), "TextureFilename", "same")
        self.assertEqual(len(t.to_bytes()), size)

    def test_insert_keeps_sorted_order(self):
        b = binding("SpellCastTimes")
        t = Table.from_bytes(pack(b, [{"ID": 1}, {"ID": 5}]), b)
        values = t.blank_row()
        values[0] = 3
        t.insert(values)
        self.assertEqual([k[0] for k in t.keys()], [1, 3, 5])
        with self.assertRaises(LayoutError):
            t.insert(values)

    def test_masks_accept_both_spellings(self):
        b = binding("SkillRaceClassInfo")  # int32 masks
        t = Table.from_bytes(pack(b, [{"ID": 1}]), b)
        t.set((1,), "RaceMask", 0xFFFFFFFF)
        self.assertEqual(Table.from_bytes(t.to_bytes(), b).get((1,), "RaceMask"), -1)
        t.set((1,), "RaceMask", 2**33)
        with self.assertRaises(LayoutError):
            t.to_bytes()


if __name__ == "__main__":
    unittest.main()
