"""End-to-end pipeline on a synthetic client base.

The MPQ step needs the pinned mpqcli (container, PATH or CLIENTPATCH_MPQCLI).
Without it the test still runs every step before packing and checks that the
build stops with a clear tool error; with it, the whole release is built
twice and must be byte-identical.
"""

import json
import os
import shutil
import tempfile
import tomllib
import unittest
from pathlib import Path

from synth import BINDINGS, ROOT, binding, pack, write

from clientpatch import mpq
from clientpatch.base import identify
from clientpatch.build import build, build_testpatch, load_config
from clientpatch.errors import BaseError, ConsistencyError, DeltaError, ToolError

HEADER = "op,key,field,value,note\n"


def have_mpqcli() -> bool:
    cfg = tomllib.loads((ROOT / "clientpatch.toml").read_text(encoding="utf-8"))
    try:
        tool = mpq.resolve_tool(cfg["mpq"], None)
        mpq.check_version(tool, cfg["mpq"])
        return True
    except ToolError:
        return False


class Pipeline(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        base = self.tmp / "base"
        write(base, "Talent", pack(binding("Talent"), [
            {"ID": 100, "TabID": 261, "SpellRank[0]": 16039}]))
        write(base, "Spell", pack(binding("Spell"), [
            {"ID": 90100, "EffectBasePoints[0]": 4, "Name_lang_enUS": "Earthen Bulwark",
             "Description_lang_enUS": "Reduces damage taken by $s1%."}]))
        write(base, "Map", pack(binding("Map"), [{"ID": 0}, {"ID": 1}]))
        # extract-base records archives outside the base; none in this client.
        (base / "foreign-archives.tsv").write_text("archive\tload_order\tdbc_count\tdbcs\n")
        self.base = base
        self.server_dbc = self.tmp / "server-dbc"
        shutil.copytree(base, self.server_dbc, ignore=shutil.ignore_patterns("*.tsv"))
        self.sql = self.tmp / "sql"
        self.sql.mkdir()
        (self.sql / "spell_template.tsv").write_text(
            "entry\teffectBasePoints1\n16039\t0\n90100\t9\n90101\t19\n")
        (self.sql / "map_template.tsv").write_text("entry\tmap_name\n0\tAzeroth\n1\tKalimdor\n")
        (self.tmp / "sources.toml").write_text(
            '[source.spell_template]\nquery = "SELECT * FROM spell_template"\nkey = "entry"\n'
            '[source.map_template]\nquery = "SELECT entry FROM map_template"\nkey = "entry"\n')
        rules = self.tmp / "consistency"
        rules.mkdir()
        (rules / "r.toml").write_text(
            '[[rule]]\nid="map"\nkind="keys_in_dbc"\nsource="map_template"\ndbc="Map"\n'
            '[[rule]]\nid="ranks"\nkind="refs_in_sql"\nsource="spell_template"\ndbc="Talent"\n'
            'scope="changed"\ncolumns=["SpellRank[0]","SpellRank[1]"]\n'
            '[[rule]]\nid="spell"\nkind="fields_equal"\nsource="spell_template"\ndbc="Spell"\n'
            'scope="changed"\n[[rule.pair]]\nsql="effectBasePoints1"\ndbc="EffectBasePoints[0]"\n')
        changes = self.tmp / "changes"
        (changes / "Talent").mkdir(parents=True)
        (changes / "Spell").mkdir(parents=True)
        (changes / "Talent" / "0001_rank2.csv").write_text(
            HEADER + "set,100,SpellRank[1],90101,#357 rank 2\n")
        (changes / "Spell" / "0001_bulwark.csv").write_text(
            HEADER + "set,90100,EffectBasePoints[0],sql:spell_template.effectBasePoints1,\n"
                     'set,90100,Description_lang_enUS,"Reduces damage taken by $s1%.\\nCap: see CV-1.",CV-1\n')
        cfg = (ROOT / "clientpatch.toml").read_text(encoding="utf-8")
        cfg = cfg.replace('bindings = "bindings"', f'bindings = "{(ROOT / "bindings").as_posix()}"')
        cfg = cfg.replace('sql_sources = "sql/sources.toml"', 'sql_sources = "sources.toml"')
        (self.tmp / "clientpatch.toml").write_text(cfg)
        (self.tmp / "bases").mkdir()
        from clientpatch.base import fingerprint_toml
        (self.tmp / "bases" / "synthetic.toml").write_text(
            fingerprint_toml(base, "synthetic", "1.12.1.5875", "synthetic test base", "test"))
        self.cfg = load_config(self.tmp / "clientpatch.toml")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_build(self, out="out"):
        return build(self.cfg, self.base, self.sql, 3, "test", self.tmp / out,
                     log=lambda *_: None, server_dbc_dir=self.server_dbc)

    def test_full_release(self):
        if not have_mpqcli():
            with self.assertRaises(ToolError):
                self.run_build()
            out = self.tmp / "out"
            self.assertTrue((out / "review.csv").is_file())
            review = (out / "review.csv").read_text()
            self.assertIn("SpellRank[1]", review)
            self.skipTest("pinned mpqcli not available: packing not exercised")
        info = self.run_build()
        out = self.tmp / "out"
        self.assertEqual(info["base"], "synthetic")
        self.assertEqual(info["server_dbcs"], ["Talent.dbc"])  # Spell is SQL-driven on the server
        self.assertTrue((out / "patch-X-v3.mpq").is_file())
        self.assertTrue((out / "server-dbc" / "Talent.dbc").is_file())
        sums = (out / "SHA256SUMS").read_text()
        self.assertIn("patch-X-v3.mpq", sums)
        info2 = self.run_build("out2")
        self.assertEqual(info["files"]["patch-X-v3.mpq"], info2["files"]["patch-X-v3.mpq"],
                         "two builds of the same input must be byte-identical")
        data = json.loads((out / "build-info.json").read_text())
        self.assertEqual(data["files"]["patch-X-v3.mpq"]["sha256"],
                         info["files"]["patch-X-v3.mpq"]["sha256"])

    def test_inconsistent_server_value_blocks(self):
        (self.tmp / "changes" / "Spell" / "0002_wrong.csv").write_text(
            HEADER + "set,90100,EffectBasePoints[0],4,deliberately not the server value\n")
        with self.assertRaisesRegex(ConsistencyError, "EffectBasePoints"):
            self.run_build()

    def test_missing_server_rank_blocks(self):
        (self.tmp / "changes" / "Talent" / "0002_rank3.csv").write_text(
            HEADER + "set,100,SpellRank[0],99999,\n")
        with self.assertRaisesRegex(ConsistencyError, "99999"):
            self.run_build()

    def test_unknown_base_is_a_clear_error(self):
        write(self.base, "Map", pack(binding("Map"), [{"ID": 0}]))  # modified client file
        with self.assertRaisesRegex(BaseError, "matches no registered client base"):
            self.run_build()
        shutil.rmtree(self.tmp / "bases")
        (self.tmp / "bases").mkdir()
        with self.assertRaisesRegex(BaseError, "no registered client base"):
            identify(self.base, self.tmp / "bases", ["Map"])

    def test_later_letter_patch_carrying_our_dbc_blocks(self):
        (self.base / "foreign-archives.tsv").write_text(
            "archive\tload_order\tdbc_count\tdbcs\n"
            "patch-Z.MPQ\tafter\t1\tTalent.dbc\n"
            "patch-A.MPQ\tbefore\t1\tSpell.dbc\n")
        with self.assertRaisesRegex(Exception, "patch-Z.MPQ .after. also carries talent"):
            self.run_build()

    def test_unknown_order_archive_blocks_and_earlier_one_warns(self):
        from clientpatch.build import check_foreign
        (self.base / "foreign-archives.tsv").write_text(
            "archive\tload_order\tdbc_count\tdbcs\n"
            "backup.MPQ\tunknown\t1\tSpell.dbc\n")
        with self.assertRaisesRegex(Exception, "backup.MPQ .unknown."):
            check_foreign(self.base, ["Spell"], "patch-X.mpq", log=lambda *_: None)
        (self.base / "foreign-archives.tsv").write_text(
            "archive\tload_order\tdbc_count\tdbcs\n"
            "patch-A.MPQ\tbefore\t1\tSpell.dbc\n"
            "patch-Y.MPQ\tafter\t2\tMap.dbc,Lock.dbc\n")
        warnings = check_foreign(self.base, ["Spell", "Talent"], "patch-X.mpq", log=lambda *_: None)
        self.assertEqual(len(warnings), 1)
        self.assertIn("patch-A.MPQ", warnings[0])

    def test_base_without_foreign_record_is_refused(self):
        (self.base / "foreign-archives.tsv").unlink()
        with self.assertRaisesRegex(Exception, "extract-base"):
            self.run_build()

    def test_server_dbcs_must_equal_the_base(self):
        write(self.server_dbc, "Talent", pack(binding("Talent"), [{"ID": 100, "TabID": 1}]))
        with self.assertRaisesRegex(Exception, "different: .'Talent.dbc'."):
            self.run_build()
        write(self.server_dbc, "SkillLine", pack(binding("SkillLine"), [{"ID": 1}]))
        (self.server_dbc / "Talent.dbc").unlink()
        shutil.copy(self.base / "Talent.dbc", self.server_dbc / "Talent.dbc")
        with self.assertRaisesRegex(Exception, "Missing in the base: .'SkillLine.dbc'."):
            self.run_build()

    def test_bad_delta_blocks(self):
        (self.tmp / "changes" / "Talent" / "0002_bad.csv").write_text(
            HEADER + "set,100,SpellRank[1],notanumber,\n")
        with self.assertRaises(DeltaError):
            self.run_build()

    @unittest.skipUnless((ROOT.parent.parent / ".git").exists(), "not inside the Git work tree")
    def test_output_inside_repo_must_be_ignored(self):
        from clientpatch.build import guard_output
        from clientpatch.errors import ClientPatchError
        with self.assertRaisesRegex(ClientPatchError, "not ignored"):
            guard_output(ROOT / "clientpatch" / "not-ignored-out")
        # a path whose parents do not exist yet is judged by its nearest existing ancestor
        with self.assertRaisesRegex(ClientPatchError, "not ignored"):
            guard_output(ROOT / "clientpatch" / "a" / "b" / "c")
        guard_output(ROOT / "dist" / "x")  # ignored by ops/clientpatch/.gitignore


@unittest.skipUnless(have_mpqcli(), "pinned mpqcli not available")
class ExtractBase(unittest.TestCase):
    def test_load_order_wins_and_own_patch_is_ignored(self):
        from clientpatch.build import extract_base
        tmp = Path(tempfile.mkdtemp())
        try:
            cfg = load_config(ROOT / "clientpatch.toml")
            tool = mpq.resolve_tool(cfg.mpq, None)
            data = tmp / "client" / "Data"
            data.mkdir(parents=True)

            def archive(name, files):
                src = tmp / ("src-" + name)
                for rel, blob in files.items():
                    write(src / "DBFilesClient", rel, blob)
                mpq.create(tool, cfg.mpq, src, data / name)

            b = binding("SpellIcon")
            archive("dbc.MPQ", {"SpellIcon": pack(b, [{"ID": 1, "TextureFilename": "old"}]),
                                "Map": pack(binding("Map"), [{"ID": 0}])})
            archive("patch-3.mpq", {"SpellIcon": pack(b, [{"ID": 1, "TextureFilename": "new"}])})
            archive("patch-X.mpq", {"SpellIcon": pack(b, [{"ID": 1, "TextureFilename": "ours"}])})
            archive("patch-Z.mpq", {"SpellIcon": pack(b, [{"ID": 1, "TextureFilename": "loc"}])})
            archive("backup.MPQ", {"Map": pack(binding("Map"), [{"ID": 9}])})
            archive("interface.MPQ", {"Ignored": b"x"})  # stock 1.12 archive: not reported
            out = tmp / "base"
            src = extract_base(cfg, tmp / "client", out, log=lambda *_: None)
            self.assertEqual(src, {"SpellIcon.dbc": "patch-3.mpq", "Map.dbc": "dbc.MPQ"})
            foreign = (out / "foreign-archives.tsv").read_text().splitlines()[2:]
            self.assertEqual(sorted(foreign), [
                "backup.MPQ\tunknown\t1\tMap.dbc",
                "patch-X.mpq\tours\t1\tSpellIcon.dbc",
                "patch-Z.mpq\tafter\t1\tSpellIcon.dbc",
            ])
            from clientpatch.wdbc import Table
            self.assertEqual(Table.read(out / "SpellIcon.dbc", b).get((1,), "TextureFilename"), "new")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


@unittest.skipUnless(have_mpqcli(), "pinned mpqcli not available")
class TestPatch(unittest.TestCase):
    def test_testpatch_is_reproducible_and_holds_only_the_version_file(self):
        tmp = Path(tempfile.mkdtemp())
        try:
            cfg = load_config(ROOT / "clientpatch.toml")
            a = build_testpatch(cfg, 1, "transport test", tmp / "a")
            b = build_testpatch(cfg, 1, "transport test", tmp / "b")
            self.assertEqual(a["files"], b["files"])
            tool = mpq.resolve_tool(cfg.mpq, None)
            self.assertEqual(sorted(mpq.list_files(tool, cfg.mpq, tmp / "a" / "patch-X-v1.mpq")),
                             ["Interface/AddOns/TWPatchProbe/TWPatchProbe.lua",
                              "Interface/AddOns/TWPatchProbe/TWPatchProbe.toc",
                              "TWPatch/version.txt"])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class LoadOrder(unittest.TestCase):
    def test_patch_letters_and_numbers(self):
        from clientpatch.build import load_relation
        ours = "patch-X.mpq"
        self.assertEqual(load_relation("patch-Z.MPQ", ours), "after")
        self.assertEqual(load_relation("patch-y.mpq", ours), "after")
        self.assertEqual(load_relation("patch-9.mpq", ours), "before")
        self.assertEqual(load_relation("patch-A.MPQ", ours), "before")
        self.assertEqual(load_relation("patch.MPQ", ours), "before")
        self.assertEqual(load_relation("patch-x.MPQ", ours), "ours")
        self.assertEqual(load_relation("backup.MPQ", ours), "unknown")
        self.assertEqual(load_relation("patch-enUS.MPQ", ours), "unknown")


if __name__ == "__main__":
    unittest.main()
