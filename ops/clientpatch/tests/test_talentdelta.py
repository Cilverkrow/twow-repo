#!/usr/bin/env python3
"""Unit tests for tools/talentdelta.py: synthetic data only, no client files.

Run from ops/clientpatch: python3 -m unittest discover -s tests
"""
import contextlib
import importlib.util
import io
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('talentdelta', ROOT / 'tools' / 'talentdelta.py')
talentdelta = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(talentdelta)

INPUTS = ROOT / 'tools' / 'inputs'
SHAMAN_TALENTS = INPUTS / '357-shaman-talents.csv'
SHAMAN_CELLS = INPUTS / '357-shaman-base-cells.csv'
SHAMAN_DELTA = ROOT / 'changes' / 'Talent' / '0357_shaman_talents.csv'
SHAMAN_SKILLS = ROOT / 'changes' / 'SkillRaceClassInfo' / '0357_shaman_swords.csv'


def talent(talent_id, tier, col, ranks=(1,), prereqs=(), tab=1):
    return {'id': talent_id, 'tab': tab, 'tier': tier, 'col': col,
            'ranks': list(ranks), 'prereqs': list(prereqs), 'flags': 0, 'required': 0, 'note': ''}


def base_cell(talent_id, tier, col, prereqs=(), tab=1):
    cell = talent(talent_id, tier, col, (), prereqs, tab)
    cell['ranks'] = None
    return cell


class LayoutTests(unittest.TestCase):
    def test_free_cells_pass(self):
        errors, warnings = talentdelta.check_layout(
            [talent(10, 0, 0, (100, 101))], [base_cell(1, 0, 1)])
        self.assertEqual(([], []), (errors, warnings))

    def test_collision_with_base_and_delta(self):
        errors, _ = talentdelta.check_layout(
            [talent(10, 0, 1, (100,)), talent(11, 2, 2, (101,)), talent(12, 2, 2, (102,))],
            [base_cell(1, 0, 1)])
        self.assertEqual(2, sum('collides' in error for error in errors))

    def test_grid_bounds(self):
        errors, _ = talentdelta.check_layout([talent(10, 7, 0, (100,)), talent(11, 0, 4, (101,))], [])
        self.assertEqual(2, sum('outside' in error for error in errors))

    def test_duplicate_ids_and_rank_spells(self):
        errors, _ = talentdelta.check_layout(
            [talent(1, 0, 0, (100,)), talent(11, 1, 0, (100,))], [base_cell(1, 3, 3)])
        self.assertTrue(any('used twice' in error for error in errors))
        self.assertTrue(any('rank spell 100' in error for error in errors))

    def test_rank_chain_gap(self):
        errors, _ = talentdelta.check_layout([talent(10, 0, 0, (100, 0, 102))], [])
        self.assertTrue(any('gap' in error for error in errors))

    def test_prerequisites(self):
        errors, _ = talentdelta.check_layout([
            talent(10, 2, 0, (100,), [(99, 0)]),          # unknown
            talent(11, 1, 1, (101,), [(12, 0)]),          # later tier
            talent(12, 3, 1, (102, 103)),
            talent(13, 4, 1, (104,), [(12, 2)]),          # rank 3 of a 2-rank talent
            talent(14, 5, 3, (105,), [(10, 0)]),          # diagonal
        ], [])
        joined = '\n'.join(errors)
        self.assertIn('unknown talent 99', joined)
        self.assertIn('later tier', joined)
        self.assertIn('rank 3 of talent 12', joined)
        self.assertIn('diagonal', joined)

    def test_arrow_over_a_talent_is_a_warning(self):
        errors, warnings = talentdelta.check_layout(
            [talent(10, 0, 3, (100,)), talent(11, 1, 3, (101,)), talent(12, 2, 3, (102,), [(10, 0)])], [])
        self.assertEqual([], errors)
        self.assertEqual(1, len(warnings))
        self.assertIn('crosses talent 11', warnings[0])

    def test_sideways_arrow_is_allowed(self):
        errors, warnings = talentdelta.check_layout(
            [talent(11, 4, 3, (101,), [(1, 0)])], [base_cell(1, 4, 2)])
        self.assertEqual(([], []), (errors, warnings))

    def test_new_talent_on_a_base_arrow_is_an_error(self):
        errors, _ = talentdelta.check_layout(
            [talent(10, 2, 1, (100,))], [base_cell(1, 1, 1), base_cell(2, 3, 1, [(1, 4)])])
        self.assertTrue(any('sits on the arrow' in error for error in errors))


class ServerTests(unittest.TestCase):
    def core(self, root, *, spells, aura_ranks, stage2, skill_rows):
        updates = root / 'sql' / 'database_updates'
        updates.mkdir(parents=True)
        clones = '\n'.join("UPDATE `tmp_spell` SET `entry` = %d, `name` = 'x';" % spell for spell in spells)
        rows = ',\n'.join('(%d, %d, %d, %d, %d, %d, %d, -1, \'c\')' % row for row in skill_rows)
        (updates / '20260101000000_world.sql').write_text(
            clones + '\nINSERT IGNORE INTO `skill_race_class_info_mod` (`Id`) VALUES\n' + rows + ';\n')
        playerbot = root / 'modules' / 'mod-playerbots' / 'src' / 'playerbot'
        playerbot.mkdir(parents=True)
        (playerbot / 'SpecAuraPolicy.h').write_text('\n'.join(
            '        { "aura %d", Both, 10, { %s } },' % (index, ', '.join(map(str, ranks)))
            for index, ranks in enumerate(aura_ranks)))
        tools = root / 'modules' / 'mod-playerbots' / 'tools'
        tools.mkdir(parents=True)
        (tools / 'build_premade_specs.py').write_text(
            'AURA_FIRST_SPELL = %r\nEXTRA_REAL_TALENTS = %r\n' % stage2)

    def skills_delta(self, root, skill_rows):
        path = root / 'skills.csv'
        lines = ['op,key,field,value,note']
        for row in skill_rows:
            lines.append('insert,%d,,copy:701,' % row[0])
            for field, value in zip(('SkillID', 'RaceMask', 'ClassMask', 'Flags', 'MinLevel', 'SkillTierID'), row[1:]):
                lines.append('set,%d,%s,%d,' % (row[0], field, value))
        path.write_text('\n'.join(lines) + '\n')
        return path

    def run_check(self, *, core_spells, core_auras, stage2, core_skills, talents, skills):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            core = root / 'core'
            self.core(core, spells=core_spells, aura_ranks=core_auras, stage2=stage2, skill_rows=core_skills)
            delta = [talent(talent_id, tier, col, ranks) for talent_id, tier, col, ranks in talents]
            return talentdelta.check_server(delta, core, 7, self.skills_delta(root, skills))

    def test_consistent_delta_passes(self):
        errors = self.run_check(
            core_spells=[100, 101, 102], core_auras=[[100, 101]], stage2=({(7, 'a'): 100, (4, 'b'): 900}, {7: {102: {'enhancement': 1}}}),
            core_skills=[(9, 43, 2047, 64, 384, 0, 0)],
            talents=[(1, 0, 0, (100, 101)), (2, 0, 1, (102,))],
            skills=[(9, 43, 2047, 64, 384, 0, 0)])
        self.assertEqual([], errors)

    def test_every_mismatch_is_reported(self):
        errors = self.run_check(
            core_spells=[100, 101], core_auras=[[100, 101, 103]], stage2=({(7, 'a'): 100, (7, 'c'): 105}, {}),
            core_skills=[(9, 43, 2047, 64, 128, 0, 0)],
            talents=[(1, 0, 0, (100, 101)), (2, 0, 1, (102,))],
            skills=[(9, 43, 2047, 64, 384, 0, 0)])
        joined = '\n'.join(errors)
        self.assertIn('rank spell 102 of talent 2 has no spell_template migration', joined)
        self.assertIn('differ from the SpecAura ranks', joined)
        self.assertIn('generator talents of class 7 (first rank spells [100, 105]) != delta talents ([100, 102])', joined)
        self.assertIn('SkillRaceClassInfo 9', joined)

    def test_range_renumbering_moves_created_spells(self):
        # #455: a later migration moves a block of spells; the rank check follows it.
        texts = ["UPDATE `tmp_spell` SET `entry` = 90100, `name` = 'x';\n"
                 "UPDATE `tmp_spell` SET `entry` = 12000, `name` = 'y';",
                 'UPDATE `spell_template` SET `entry` = `entry` - 28999 WHERE `entry` BETWEEN 90001 AND 90219;']
        self.assertEqual({61101, 12000}, talentdelta.server_spells(texts))

    def test_old_core_gives_a_clear_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(FileNotFoundError):
                talentdelta.migration_texts(pathlib.Path(tmp))


class GeneratorTests(unittest.TestCase):
    def test_delta_has_an_insert_and_the_non_zero_fields(self):
        text = talentdelta.to_delta([talent(10, 2, 1, (100, 101), [(9, 4)], tab=263)], 'line one')
        self.assertEqual([
            'op,key,field,value,note', '# line one', 'insert,10,,,',
            'set,10,TabID,263,', 'set,10,TierID,2,', 'set,10,ColumnIndex,1,',
            'set,10,SpellRank[0],100,rank 1', 'set,10,SpellRank[1],101,rank 2',
            'set,10,PrereqTalent[0],9,', 'set,10,PrereqRank[0],4,needs rank 5',
        ], text.splitlines())

    def test_layout_errors_write_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / 't.csv').write_text(SHAMAN_TALENTS.read_text().replace('9010,263,6,2,', '9010,263,6,1,'))
            out = root / 'out.csv'
            with contextlib.redirect_stdout(io.StringIO()):
                code = talentdelta.main(['--talents', str(root / 't.csv'),
                                         '--base-cells', str(SHAMAN_CELLS), '--out', str(out)])
            self.assertEqual(1, code)
            self.assertFalse(out.exists())


class BaseDbcTests(unittest.TestCase):
    def test_base_cells_and_ranks_come_from_a_talent_dbc(self):
        import synth
        rows = [{'ID': 251, 'TabID': 263, 'TierID': 0, 'ColumnIndex': 1, 'SpellRank[0]': 1, 'SpellRank[1]': 2},
                {'ID': 260, 'TabID': 263, 'TierID': 3, 'ColumnIndex': 1, 'SpellRank[0]': 3,
                 'PrereqTalent[0]': 251, 'PrereqRank[0]': 1},
                {'ID': 300, 'TabID': 264, 'TierID': 0, 'ColumnIndex': 0, 'SpellRank[0]': 4}]
        with tempfile.TemporaryDirectory() as tmp:
            path = synth.write(pathlib.Path(tmp), 'Talent', synth.pack(synth.binding('Talent'), rows))
            cells = talentdelta.load_base_dbc(path, {263})
        self.assertEqual([251, 260], sorted(cell['id'] for cell in cells))
        errors, _ = talentdelta.check_layout(
            [talent(10, 2, 1, (100,), tab=263), talent(11, 5, 1, (101,), [(251, 2)], tab=263)], cells)
        self.assertTrue(any('sits on the arrow from talent 251 to talent 260' in e for e in errors))
        self.assertTrue(any('rank 3 of talent 251, which has 2 ranks' in e for e in errors))


class ShamanChangeTests(unittest.TestCase):
    """The committed #357 talents (layout only; the server check needs --core)."""

    def test_layout_passes_without_warnings(self):
        delta = talentdelta.load_talents(SHAMAN_TALENTS)
        base = talentdelta.load_base(SHAMAN_CELLS)
        errors, warnings = talentdelta.check_layout(delta, base)
        self.assertEqual([], errors)
        # S2-2 (owner 2026-09-28): Shield Ward needs Shield Constitution 3/3, a clean
        # arrow in the same column instead of one over Shield Constitution.
        self.assertEqual([], warnings)
        shield_ward = next(talent for talent in delta if talent['id'] == 9009)
        self.assertEqual([(9007, 2)], shield_ward['prereqs'])
        self.assertEqual(set(range(9001, 9011)), {talent['id'] for talent in delta})
        self.assertEqual({263}, {talent['tab'] for talent in delta})

    def test_committed_delta_is_current(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = talentdelta.main(['--talents', str(SHAMAN_TALENTS), '--base-cells', str(SHAMAN_CELLS),
                                     '--check', str(SHAMAN_DELTA)])
        self.assertEqual(0, code, output.getvalue())
        self.assertIn('TALENTDELTA=PASS talents=10 errors=0 warnings=0 server=skipped', output.getvalue())

    def test_skill_rows_match_the_server_rows_of_core_217(self):
        rows = talentdelta.delta_rows(SHAMAN_SKILLS)
        self.assertEqual({90043, 90055}, set(rows))
        for key, skill in ((90043, '43'), (90055, '55')):
            self.assertEqual({'SkillID': skill, 'RaceMask': '2047', 'ClassMask': '64', 'Flags': '384',
                              'MinLevel': '0', 'SkillTierID': '0'}, rows[key])


if __name__ == '__main__':
    unittest.main()
