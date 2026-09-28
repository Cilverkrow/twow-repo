#!/usr/bin/env python3
"""Unit tests for talentdelta.py: synthetic data only, no client files.

Run: python3 -m unittest ops/clientpatch/test_talentdelta.py
"""
import contextlib
import importlib.util
import io
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('talentdelta', HERE / 'talentdelta.py')
talentdelta = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(talentdelta)

SHAMAN = HERE / 'changes' / '0357-shaman-talents'


def talent(talent_id, tier, col, ranks=(1,), prereqs=(), tab=1):
    return {'id': talent_id, 'tab': tab, 'tier': tier, 'col': col,
            'ranks': list(ranks), 'prereqs': list(prereqs)}


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
        (tools / 'build_premade_specs.py').write_text('STAGE2_TALENTS = %r\n' % stage2)

    def change(self, root, talents, spell_inserts, skill_rows):
        change = root / 'change'
        change.mkdir()
        header = (['op', 'ID', 'TabID', 'TierID', 'ColumnIndex'] +
                  ['SpellRank_%d' % k for k in range(9)] +
                  ['PrereqTalent_%d' % k for k in range(3)] +
                  ['PrereqRank_%d' % k for k in range(3)] + ['Flags', 'RequiredSpellID', 'comment'])
        lines = [','.join(header)]
        for talent_id, tier, col, ranks in talents:
            cells = ['insert', talent_id, 1, tier, col] + list(ranks) + [0] * (9 - len(ranks)) + [0] * 8 + ['']
            lines.append(','.join(map(str, cells)))
        (change / 'Talent.csv').write_text('\n'.join(lines) + '\n')
        (change / 'base-cells.csv').write_text('TabID,ID,TierID,ColumnIndex,PrereqTalent_0,PrereqRank_0\n')
        (change / 'Spell.csv').write_text('op,ID,source,fields,comment\n' + ''.join(
            'insert,%d,spell_template,all,\n' % spell for spell in spell_inserts))
        (change / 'SkillRaceClassInfo.csv').write_text(
            'op,ID,SkillID,RaceMask,ClassMask,Flags,MinLevel,SkillTierID,SkillCostIndex,comment\n' + ''.join(
                'insert,%d,%d,%d,%d,%d,%d,%d,@1,\n' % row for row in skill_rows))
        return change

    def run_check(self, *, core_spells, core_auras, stage2, core_skills, talents, inserts, skills):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            core = root / 'core'
            self.core(core, spells=core_spells, aura_ranks=core_auras, stage2=stage2, skill_rows=core_skills)
            change = self.change(root, talents, inserts, skills)
            delta = talentdelta.load_talents(change / 'Talent.csv')
            return talentdelta.check_server(change, delta, core, 7)

    def test_consistent_delta_passes(self):
        errors = self.run_check(
            core_spells=[100, 101, 102], core_auras=[[100, 101]], stage2={7: {1, 2}},
            core_skills=[(9, 43, 2047, 64, 384, 0, 0)],
            talents=[(1, 0, 0, (100, 101)), (2, 0, 1, (102,))], inserts=[100, 101, 102],
            skills=[(9, 43, 2047, 64, 384, 0, 0)])
        self.assertEqual([], errors)

    def test_every_mismatch_is_reported(self):
        errors = self.run_check(
            core_spells=[100, 101], core_auras=[[100, 101, 103]], stage2={7: {1, 5}},
            core_skills=[(9, 43, 2047, 64, 128, 0, 0)],
            talents=[(1, 0, 0, (100, 101)), (2, 0, 1, (102,))], inserts=[100, 104],
            skills=[(9, 43, 2047, 64, 384, 0, 0)])
        joined = '\n'.join(errors)
        self.assertIn('rank spell 102 of talent 2 has no spell_template migration', joined)
        self.assertIn('Spell.csv inserts 104', joined)
        self.assertIn('differ from the SpecAura ranks', joined)
        self.assertIn('STAGE2_TALENTS[7]', joined)
        self.assertIn('SkillRaceClassInfo 9', joined)

    def test_old_core_gives_a_clear_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(FileNotFoundError):
                talentdelta.migration_texts(pathlib.Path(tmp))


class ShamanChangeTests(unittest.TestCase):
    """The committed #357 delta itself (layout only; the server check needs --core)."""

    def test_layout_passes_with_the_known_arrow_warning(self):
        delta = talentdelta.load_talents(SHAMAN / 'Talent.csv')
        base = talentdelta.load_base(SHAMAN / 'base-cells.csv')
        errors, warnings = talentdelta.check_layout(delta, base)
        self.assertEqual([], errors)
        # Decision S2-2: the owner's arrow R5/C4 -> R7/C4 passes Shield Constitution.
        self.assertEqual(['talent 9009: arrow from talent 9005 crosses talent 9007 at tier 5 column 3'],
                         warnings)
        self.assertEqual(set(range(9001, 9011)), {talent['id'] for talent in delta})
        self.assertEqual({263}, {talent['tab'] for talent in delta})

    def test_cli_reports_pass(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = talentdelta.main(['--change', str(SHAMAN)])
        self.assertEqual(0, code)
        self.assertIn('TALENTDELTA=PASS talents=10 errors=0 warnings=1 server=skipped', output.getvalue())


if __name__ == '__main__':
    unittest.main()
