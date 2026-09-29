#!/usr/bin/env python3
"""Generate and check a Talent.dbc delta for the clientpatch pipeline.

Input is a talent list (one row per talent, the Talent.dbc fields spelled out):

    ID,TabID,TierID,ColumnIndex,SpellRank_0..8,PrereqTalent_0..2,PrereqRank_0..2,
    Flags,RequiredSpellID,note

The output is a delta in the pipeline format (changes/Talent/NNNN_*.csv,
op,key,field,value,note; see ../README.md "Delta format"): one insert per
talent plus a set for every non-zero field.

Before it writes anything it checks the layout, against the occupied cells of
the base tree (--base-dbc: the extracted base Talent.dbc; or --base-cells: a
committed list of IDs and positions, for CI without a client):

  * grid (7 tiers x 4 columns), collisions with base or new talents;
  * duplicate talent IDs or rank spells, gaps in a rank chain;
  * unknown, cross-tab or later-tier prerequisites, a prerequisite rank above
    its maximum (base talents too when --base-dbc is given);
  * diagonal arrows (the 1.12 talent frame draws only straight down or sideways);
  * a new talent placed on an existing arrow.

An arrow that passes over another talent is a warning: legal data, but it
looks wrong in the client.

With --core it also checks the talents against the server sources of a
twow-core checkout (read-only, no database): every rank spell is created by
a migration, SpecAura talents carry the same ranks in the same order, with
--class the talent IDs equal STAGE2_TALENTS[class] of build_premade_specs.py,
and --skills rows (a SkillRaceClassInfo delta) match skill_race_class_info_mod.

Nothing here is class-specific. Standard library only (plus the clientpatch
package for --base-dbc).

    python3 tools/talentdelta.py --talents tools/inputs/357-shaman-talents.csv \
        --base-cells tools/inputs/357-shaman-base-cells.csv \
        --out changes/Talent/0357_shaman_talents.csv
    python3 tools/talentdelta.py ... --check changes/Talent/0357_shaman_talents.csv
    python3 tools/talentdelta.py ... --core ../../core --class 7 \
        --skills changes/SkillRaceClassInfo/0357_shaman_swords.csv
"""
import argparse
import csv
import importlib.util
import io
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
TIERS = 7
COLUMNS = 4
MAX_RANKS = 9


def _int(value):
    return int(value) if value not in ('', None) else 0


def load_talents(path):
    talents = []
    with open(path, newline='') as handle:
        for row in csv.DictReader(handle):
            ranks = [_int(row['SpellRank_%d' % k]) for k in range(MAX_RANKS)]
            while ranks and ranks[-1] == 0:
                ranks.pop()
            prereqs = [(_int(row['PrereqTalent_%d' % k]), _int(row['PrereqRank_%d' % k]))
                       for k in range(3) if _int(row['PrereqTalent_%d' % k])]
            talents.append({
                'id': _int(row['ID']), 'tab': _int(row['TabID']),
                'tier': _int(row['TierID']), 'col': _int(row['ColumnIndex']),
                'ranks': ranks, 'prereqs': prereqs,
                'flags': _int(row.get('Flags')), 'required': _int(row.get('RequiredSpellID')),
                'note': (row.get('note') or '').strip(),
            })
    return talents


def load_base(path):
    """Committed base cells: TabID,ID,TierID,ColumnIndex,PrereqTalent_0,PrereqRank_0."""
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


def load_base_dbc(path, tabs):
    """Base cells of the given tabs from an extracted Talent.dbc (ranks known)."""
    sys.path.insert(0, str(ROOT))
    from clientpatch.binding import load_binding
    from clientpatch.wdbc import Table
    table = Table.read(pathlib.Path(path), load_binding(ROOT / 'bindings' / '1.12.1.5875' / 'Talent.toml'))
    cells = []
    for key in table.keys():
        if table.get(key, 'TabID') not in tabs:
            continue
        ranks = [table.get(key, 'SpellRank[%d]' % k) for k in range(MAX_RANKS)]
        while ranks and ranks[-1] == 0:
            ranks.pop()
        prereqs = [(table.get(key, 'PrereqTalent[%d]' % k), table.get(key, 'PrereqRank[%d]' % k))
                   for k in range(3) if table.get(key, 'PrereqTalent[%d]' % k)]
        cells.append({'id': key[0], 'tab': table.get(key, 'TabID'),
                      'tier': table.get(key, 'TierID'), 'col': table.get(key, 'ColumnIndex'),
                      'ranks': ranks, 'prereqs': prereqs})
    return cells


def to_delta(talents, header=''):
    """The pipeline delta for the talents (insert + one set per non-zero field)."""
    out = io.StringIO()
    writer = csv.writer(out, lineterminator='\n')
    writer.writerow(['op', 'key', 'field', 'value', 'note'])
    for line in header.splitlines():
        out.write('# %s\n' % line)
    for talent in sorted(talents, key=lambda t: t['id']):
        key = talent['id']
        writer.writerow(['insert', key, '', '', talent['note']])
        writer.writerow(['set', key, 'TabID', talent['tab'], ''])
        if talent['tier']:
            writer.writerow(['set', key, 'TierID', talent['tier'], ''])
        if talent['col']:
            writer.writerow(['set', key, 'ColumnIndex', talent['col'], ''])
        for index, spell in enumerate(talent['ranks']):
            writer.writerow(['set', key, 'SpellRank[%d]' % index, spell, 'rank %d' % (index + 1)])
        for index, (prereq, rank) in enumerate(talent['prereqs']):
            writer.writerow(['set', key, 'PrereqTalent[%d]' % index, prereq, ''])
            if rank:
                writer.writerow(['set', key, 'PrereqRank[%d]' % index, rank, 'needs rank %d' % (rank + 1)])
        if talent['flags']:
            writer.writerow(['set', key, 'Flags', talent['flags'], ''])
        if talent['required']:
            writer.writerow(['set', key, 'RequiredSpellID', talent['required'], ''])
    return out.getvalue()


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


def delta_rows(path):
    """{key: {field: value}} of a pipeline delta (inserts and sets)."""
    rows = {}
    with open(path, newline='') as handle:
        lines = [line for line in handle if not line.startswith('#')]
    for row in csv.DictReader(lines):
        key = _int(row['key'])
        if row['op'] == 'insert':
            rows.setdefault(key, {})
        elif row['op'] == 'set':
            rows.setdefault(key, {})[row['field']] = row['value']
    return rows


def check_server(talents, core, cls=None, skills=None):
    errors = []
    texts = migration_texts(core)
    spells = server_spells(texts)
    for talent in talents:
        for spell in talent['ranks']:
            if spell not in spells:
                errors.append('rank spell %d of talent %d has no spell_template migration' %
                              (spell, talent['id']))

    aura_lists = spec_aura_ranks(core)
    for talent in talents:
        for ranks in aura_lists:
            if set(ranks) & set(talent['ranks']) and ranks != talent['ranks']:
                errors.append('talent %d ranks %s differ from the SpecAura ranks %s' %
                              (talent['id'], talent['ranks'], ranks))

    if cls is not None:
        expected = stage2_talents(core, cls)
        actual = {talent['id'] for talent in talents}
        if expected != actual:
            errors.append('STAGE2_TALENTS[%d] %s != delta talents %s' %
                          (cls, sorted(expected), sorted(actual)))

    if skills:
        server_rows = server_skill_rows(texts)
        fields = ('SkillID', 'RaceMask', 'ClassMask', 'Flags', 'MinLevel', 'SkillTierID')
        for key, values in sorted(delta_rows(skills).items()):
            wanted = [_int(values.get(field)) for field in fields]
            have = server_rows.get(key)
            if have != wanted:
                errors.append('SkillRaceClassInfo %d %s != skill_race_class_info_mod %s' %
                              (key, wanted, have))
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--talents', required=True, help='talent list (see the module doc)')
    base = parser.add_mutually_exclusive_group(required=True)
    base.add_argument('--base-cells', help='committed occupied cells of the touched tabs')
    base.add_argument('--base-dbc', help='extracted base Talent.dbc')
    parser.add_argument('--out', help='write the delta here')
    parser.add_argument('--check', help='fail when this committed delta is not what --talents generates')
    parser.add_argument('--header', default='', help='comment lines for the top of the delta')
    parser.add_argument('--core', help='twow-core checkout for the server check')
    parser.add_argument('--class', dest='cls', type=int,
                        help='class id whose STAGE2_TALENTS must equal the talents')
    parser.add_argument('--skills', help='SkillRaceClassInfo delta to compare with the server')
    args = parser.parse_args(argv)

    try:
        talents = load_talents(args.talents)
        tabs = {talent['tab'] for talent in talents}
        cells = load_base(args.base_cells) if args.base_cells else load_base_dbc(args.base_dbc, tabs)
        errors, warnings = check_layout(talents, [c for c in cells if c['tab'] in tabs])
        if args.core:
            errors += check_server(talents, args.core, args.cls, args.skills)
    except (OSError, ValueError, KeyError) as error:
        print('ERROR %s' % error)
        return 1

    for warning in warnings:
        print('WARN  %s' % warning)
    for error in errors:
        print('ERROR %s' % error)
    stale = False
    if not errors:
        text = to_delta(talents, args.header)
        if args.out:
            pathlib.Path(args.out).write_text(text, encoding='utf-8', newline='\n')
        if args.check:
            committed = pathlib.Path(args.check).read_text(encoding='utf-8')
            stale = [line for line in committed.splitlines() if not line.startswith('#')] != \
                    [line for line in text.splitlines() if not line.startswith('#')]
            if stale:
                print('ERROR %s is not what %s generates; run with --out' % (args.check, args.talents))
    print('TALENTDELTA=%s talents=%d errors=%d warnings=%d server=%s' % (
        'FAIL' if errors or stale else 'PASS', len(talents), len(errors) + int(bool(stale)),
        len(warnings), 'checked' if args.core else 'skipped'))
    return 1 if errors or stale else 0


if __name__ == '__main__':
    sys.exit(main())
