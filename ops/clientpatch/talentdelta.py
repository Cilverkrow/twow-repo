#!/usr/bin/env python3
"""Check a client-patch talent delta: tree layout and server consistency.

A talent delta is a change directory under ops/clientpatch/changes/ with

  Talent.csv              rows to insert into Talent.dbc (op,ID,TabID,TierID,...)
  base-cells.csv          occupied cells of the touched tabs in the base client
                          (TabID,ID,TierID,ColumnIndex,PrereqTalent_0,PrereqRank_0)
  Spell.csv               optional: Spell.dbc rows built from spell_template
  SkillRaceClassInfo.csv  optional: rows the server mirrors in
                          skill_race_class_info_mod

The layout check needs no client files: it proves that the new talents fit
the grid (7 tiers x 4 columns), do not collide with base or delta talents,
and that every prerequisite arrow is one the 1.12 talent frame can draw
(straight down or sideways). Arrows that pass over an occupied cell are
reported as warnings: they are legal data but look wrong in the client.

With --core the delta is also checked against the server sources of a
twow-core checkout (read-only, no database needed):

  * every rank spell and every Spell.csv insert exists as a spell_template
    row created by a migration under sql/database_updates;
  * talents whose rank spells are SpecAura auras (SpecAuraPolicy.h) carry
    exactly the same ranks in the same order;
  * with --class, the delta's talent ids equal STAGE2_TALENTS[class] of
    tools/build_premade_specs.py;
  * every SkillRaceClassInfo.csv row matches a skill_race_class_info_mod
    row of a migration.

Exit code 0 = no errors (warnings allowed), 1 = errors. Standard library only.

Usage:
  python3 ops/clientpatch/talentdelta.py --change ops/clientpatch/changes/0357-shaman-talents
  python3 ops/clientpatch/talentdelta.py --change <dir> --core core --class 7
"""
import argparse
import csv
import importlib.util
import pathlib
import re
import sys

TIERS = 7
COLUMNS = 4
MAX_RANKS = 9


def _int(value):
    return int(value) if value not in ('', None) else 0


def load_talents(path):
    talents = []
    with open(path, newline='') as handle:
        for row in csv.DictReader(handle):
            if row['op'] != 'insert':
                raise ValueError('%s: only op=insert is supported, got %r' % (path, row['op']))
            ranks = [_int(row['SpellRank_%d' % k]) for k in range(MAX_RANKS)]
            while ranks and ranks[-1] == 0:
                ranks.pop()
            prereqs = [(_int(row['PrereqTalent_%d' % k]), _int(row['PrereqRank_%d' % k]))
                       for k in range(3) if _int(row['PrereqTalent_%d' % k])]
            talents.append({
                'id': _int(row['ID']), 'tab': _int(row['TabID']),
                'tier': _int(row['TierID']), 'col': _int(row['ColumnIndex']),
                'ranks': ranks, 'prereqs': prereqs,
            })
    return talents


def load_base(path):
    cells = []
    with open(path, newline='') as handle:
        for row in csv.DictReader(handle):
            prereq = _int(row.get('PrereqTalent_0'))
            cells.append({
                'id': _int(row['ID']), 'tab': _int(row['TabID']),
                'tier': _int(row['TierID']), 'col': _int(row['ColumnIndex']),
                'ranks': None,  # unknown without the client DBC
                'prereqs': [(prereq, _int(row.get('PrereqRank_0')))] if prereq else [],
            })
    return cells


def arrow_cells(source, target):
    """Cells an arrow from source to target passes over (ends excluded)."""
    if source['col'] == target['col']:
        return [(tier, source['col']) for tier in range(source['tier'] + 1, target['tier'])]
    if source['tier'] == target['tier']:
        low, high = sorted((source['col'], target['col']))
        return [(source['tier'], col) for col in range(low + 1, high)]
    return None  # the 1.12 talent frame draws no diagonal arrows


def check_layout(delta, base):
    """Return (errors, warnings) for the delta against the base cells."""
    errors, warnings = [], []
    everything = base + delta
    by_id = {}
    for talent in everything:
        if talent['id'] in by_id:
            errors.append('talent id %d is used twice' % talent['id'])
        by_id[talent['id']] = talent

    occupied = {}
    for talent in everything:
        cell = (talent['tab'], talent['tier'], talent['col'])
        if not (0 <= talent['tier'] < TIERS and 0 <= talent['col'] < COLUMNS):
            errors.append('talent %d is outside the %dx%d grid (tier %d, column %d)' %
                          (talent['id'], TIERS, COLUMNS, talent['tier'], talent['col']))
        if cell in occupied:
            errors.append('talent %d collides with talent %d at tab %d tier %d column %d' %
                          (talent['id'], occupied[cell], cell[0], cell[1], cell[2]))
        occupied[cell] = talent['id']

    rank_owner = {}
    for talent in delta:
        if not talent['ranks'] or 0 in talent['ranks']:
            errors.append('talent %d has no rank spells or a gap in its rank chain' % talent['id'])
        for spell in talent['ranks']:
            if spell in rank_owner:
                errors.append('rank spell %d is used by talents %d and %d' %
                              (spell, rank_owner[spell], talent['id']))
            rank_owner[spell] = talent['id']

    for talent in delta:
        for prereq_id, prereq_rank in talent['prereqs']:
            prereq = by_id.get(prereq_id)
            if not prereq:
                errors.append('talent %d needs unknown talent %d' % (talent['id'], prereq_id))
                continue
            if prereq['tab'] != talent['tab']:
                errors.append('talent %d needs talent %d of another tab' % (talent['id'], prereq_id))
                continue
            if prereq['tier'] > talent['tier']:
                errors.append('talent %d needs talent %d of a later tier' % (talent['id'], prereq_id))
                continue
            if prereq['ranks'] is not None and prereq_rank >= len(prereq['ranks']):
                errors.append('talent %d needs rank %d of talent %d, which has %d ranks' %
                              (talent['id'], prereq_rank + 1, prereq_id, len(prereq['ranks'])))
            path = arrow_cells(prereq, talent)
            if path is None:
                errors.append('talent %d: arrow from talent %d is diagonal' % (talent['id'], prereq_id))
                continue
            for tier, col in path:
                blocker = occupied.get((talent['tab'], tier, col))
                if blocker:
                    warnings.append('talent %d: arrow from talent %d crosses talent %d at tier %d column %d' %
                                    (talent['id'], prereq_id, blocker, tier, col))

    # Arrows of base talents must not run over new cells either.
    delta_ids = {talent['id'] for talent in delta}
    for talent in base:
        for prereq_id, _ in talent['prereqs']:
            prereq = by_id.get(prereq_id)
            path = arrow_cells(prereq, talent) if prereq else None
            for tier, col in path or []:
                blocker = occupied.get((talent['tab'], tier, col))
                if blocker in delta_ids:
                    errors.append('new talent %d sits on the arrow from talent %d to talent %d' %
                                  (blocker, prereq_id, talent['id']))
    return errors, warnings


# --- server side -----------------------------------------------------------------

def migration_texts(core):
    root = pathlib.Path(core) / 'sql' / 'database_updates'
    if not root.is_dir():
        raise FileNotFoundError('%s is not a twow-core checkout (no sql/database_updates)' % core)
    return [path.read_text(errors='replace') for path in sorted(root.rglob('*.sql'))]


def server_spells(texts):
    spells = set()
    for text in texts:
        spells.update(int(value) for value in re.findall(r'SET `entry` = (\d+),', text))
    return spells


def server_skill_rows(texts):
    rows = {}
    pattern = re.compile(r'\((\d+), (\d+), (\d+), (\d+), (\d+), (\d+), (\d+), (-?\d+),')
    for text in texts:
        for block in re.findall(r'INTO `skill_race_class_info_mod`[^;]*;', text, re.S):
            for match in pattern.finditer(block):
                values = [int(value) for value in match.groups()]
                rows[values[0]] = values[1:7]
    return rows


def spec_aura_ranks(core):
    header = pathlib.Path(core) / 'modules' / 'mod-playerbots' / 'src' / 'playerbot' / 'SpecAuraPolicy.h'
    ranks = []
    for match in re.finditer(r'\{\s*"[^"]+",\s*[^,]+,\s*\d+,\s*\{([\d,\s]+)\}\s*\}', header.read_text()):
        ranks.append([int(value) for value in match.group(1).split(',') if value.strip()])
    return ranks


def stage2_talents(core, cls):
    generator = pathlib.Path(core) / 'modules' / 'mod-playerbots' / 'tools' / 'build_premade_specs.py'
    spec = importlib.util.spec_from_file_location('premade_specs_generator', generator)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    table = getattr(module, 'STAGE2_TALENTS', None)
    if table is None:
        raise ValueError('%s has no STAGE2_TALENTS table (core too old for this delta)' % generator)
    return set(table.get(cls, ()))


def load_rows(path, key='ID'):
    if not path.is_file():
        return []
    with open(path, newline='') as handle:
        return list(csv.DictReader(handle))


def check_server(change, delta, core, cls=None):
    errors = []
    texts = migration_texts(core)
    spells = server_spells(texts)
    for talent in delta:
        for spell in talent['ranks']:
            if spell not in spells:
                errors.append('rank spell %d of talent %d has no spell_template migration' %
                              (spell, talent['id']))
    for row in load_rows(change / 'Spell.csv'):
        if row['op'] == 'insert' and _int(row['ID']) not in spells:
            errors.append('Spell.csv inserts %s, but no migration creates it' % row['ID'])

    aura_lists = spec_aura_ranks(core)
    for talent in delta:
        for ranks in aura_lists:
            if set(ranks) & set(talent['ranks']) and ranks != talent['ranks']:
                errors.append('talent %d ranks %s differ from the SpecAura ranks %s' %
                              (talent['id'], talent['ranks'], ranks))

    if cls is not None:
        expected = stage2_talents(core, cls)
        actual = {talent['id'] for talent in delta}
        if expected != actual:
            errors.append('STAGE2_TALENTS[%d] %s != delta talents %s' %
                          (cls, sorted(expected), sorted(actual)))

    server_rows = server_skill_rows(texts)
    for row in load_rows(change / 'SkillRaceClassInfo.csv'):
        wanted = [_int(row[field]) for field in
                  ('SkillID', 'RaceMask', 'ClassMask', 'Flags', 'MinLevel', 'SkillTierID')]
        have = server_rows.get(_int(row['ID']))
        if have != wanted:
            errors.append('SkillRaceClassInfo %s %s != skill_race_class_info_mod %s' %
                          (row['ID'], wanted, have))
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--change', required=True, help='change directory with Talent.csv')
    parser.add_argument('--core', help='twow-core checkout for the server check')
    parser.add_argument('--class', dest='cls', type=int,
                        help='class id whose STAGE2_TALENTS must equal the delta')
    args = parser.parse_args(argv)

    change = pathlib.Path(args.change)
    try:
        delta = load_talents(change / 'Talent.csv')
        base = load_base(change / 'base-cells.csv')
        errors, warnings = check_layout(delta, base)
        if args.core:
            errors += check_server(change, delta, args.core, args.cls)
    except (OSError, ValueError, KeyError) as error:
        print('ERROR %s' % error)
        return 1

    for warning in warnings:
        print('WARN  %s' % warning)
    for error in errors:
        print('ERROR %s' % error)
    print('TALENTDELTA=%s talents=%d errors=%d warnings=%d server=%s' % (
        'FAIL' if errors else 'PASS', len(delta), len(errors), len(warnings),
        'checked' if args.core else 'skipped'))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
