"""clientpatch.ui: talent frame buttons (#455, owner decision #409: 30). Synthetic
snippets only - the real interface files are client data and stay out of Git."""

import hashlib
import shutil
import tempfile
import tomllib
import unittest
from pathlib import Path

from synth import ROOT, binding, pack

from clientpatch import ui
from clientpatch.wdbc import Table

LUA = "-- synthetic\nMAX_NUM_TALENTS = 20;\nMAX_NUM_TALENT_TIERS = 8;\n"
XML = "<Ui>\r\n\t<Frame>\r\n" + "".join(
    f'\t\t<Button name="TalentFrameTalent{i}" inherits="TalentButtonTemplate" id="{i}"/>\r\n'
    for i in range(1, 21)) + "\t</Frame>\r\n</Ui>\r\n"
MEMBER_LUA = "Interface\\AddOns\\Blizzard_TalentUI\\Blizzard_TalentUI.lua"
MEMBER_XML = "Interface\\AddOns\\Blizzard_TalentUI\\Blizzard_TalentUI.xml"


def cfg(lua_sha, xml_sha, buttons=30):
    return {"ui": {"talent_buttons": buttons, "file": [
        {"path": MEMBER_LUA, "sha256": lua_sha, "transform": "talent_buttons_lua"},
        {"path": MEMBER_XML, "sha256": xml_sha, "transform": "talent_buttons_xml"}]}}


class Transforms(unittest.TestCase):
    def test_lua_limit(self):
        self.assertIn("MAX_NUM_TALENTS = 30;", ui.talent_buttons_lua(LUA, 30))
        with self.assertRaisesRegex(ui.UiError, "exactly one match, found 0"):
            ui.talent_buttons_lua(LUA.replace("= 20", "= 24"), 30)

    def test_xml_buttons_keep_indent_and_line_ending(self):
        out = ui.talent_buttons_xml(XML, 30)
        for i in range(1, 31):
            self.assertEqual(1, out.count(f'name="TalentFrameTalent{i}" '), i)
            self.assertIn(f'\t\t<Button name="TalentFrameTalent{i}" inherits="TalentButtonTemplate" id="{i}"/>\r\n', out)
        self.assertNotIn("TalentFrameTalent31", out)
        self.assertTrue(out.endswith("\t</Frame>\r\n</Ui>\r\n"))

    def test_xml_with_unexpected_buttons_stops(self):
        with self.assertRaisesRegex(ui.UiError, "TalentFrameTalent1..20"):
            ui.talent_buttons_xml(XML.replace("id=\"20\"/>", "id=\"20\"/>\r\n<Button name=\"TalentFrameTalent21\"/>"), 30)


class BuildFiles(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.base = self.tmp / "base"
        for member, text in ((MEMBER_LUA, LUA), (MEMBER_XML, XML)):
            p = ui.local_path(self.base, member)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(text.encode("latin-1"))
        self.sha = [hashlib.sha256(t.encode("latin-1")).hexdigest() for t in (LUA, XML)]

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_files_are_staged_with_hashes(self):
        rows = ui.build_files(cfg(*self.sha), self.base, self.tmp / "staging")
        self.assertEqual([r["source_sha256"] for r in rows], self.sha)
        lua = (self.tmp / "staging" / "Interface" / "AddOns" / "Blizzard_TalentUI" / "Blizzard_TalentUI.lua").read_text()
        self.assertIn("MAX_NUM_TALENTS = 30;", lua)

    def test_changed_turtle_file_stops_the_build(self):
        with self.assertRaisesRegex(ui.UiError, "Turtle changed the file"):
            ui.build_files(cfg("0" * 64, self.sha[1]), self.base, self.tmp / "staging")

    def test_missing_source_is_a_clear_error(self):
        ui.local_path(self.base, MEMBER_XML).unlink()
        with self.assertRaisesRegex(ui.UiError, "not in the base"):
            ui.build_files(cfg(*self.sha), self.base, self.tmp / "staging")


class TalentsPerTab(unittest.TestCase):
    def table(self, per_tab):
        rows, n = [], 1
        for tab, count in per_tab.items():
            for _ in range(count):
                rows.append({"ID": n, "TabID": tab})
                n += 1
        return Table.from_bytes(pack(binding("Talent"), rows), binding("Talent"))

    def test_26_fits_30_but_not_20(self):
        t = self.table({181: 26, 263: 26, 261: 17})
        ui.check_talents_per_tab(t, 30)
        with self.assertRaisesRegex(ui.UiError, r"\(20\): \{181: 26, 263: 26\}"):
            ui.check_talents_per_tab(t, None)

    def test_31_does_not_fit_30(self):
        with self.assertRaisesRegex(ui.UiError, r"\{181: 31\}"):
            ui.check_talents_per_tab(self.table({181: 31}), 30)


class RepoConfig(unittest.TestCase):
    def test_config_names_both_files_and_30_buttons(self):
        data = tomllib.loads((ROOT / "clientpatch.toml").read_text(encoding="utf-8"))
        self.assertEqual(30, ui.talent_buttons(data))
        self.assertEqual({MEMBER_LUA, MEMBER_XML}, {f["path"] for f in ui.files(data)})
        for f in ui.files(data):
            self.assertIn(f["transform"], ui.TRANSFORMS)
            self.assertRegex(f["sha256"], r"^[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main()
