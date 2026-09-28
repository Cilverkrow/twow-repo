# ops/clientpatch: client patch sources and checks

Home of our **own** client-patch changes (twow-repo#409, design
`docs/design/client-patch-pipeline.md` in PR #410). Git holds only change
sources, tools and tests. **Never** client files: no DBC, MPQ, BLP or extracted
data (ADR-0024 invariant 5; the repos are public).

The general tool chain comes with stage 1 (CL-409): the delta schema, the WDBC
reader/writer, `dbcdiff`, the build script (deltas → DBC → `patch-X.mpq`) and
the consistency check against the server SQL. This directory already holds:

| Path | What |
|---|---|
| `changes/<NNNN>-<topic>/` | one change: CSV row deltas per DBC plus a README (see below) |
| `talentdelta.py` | layout and server check for **any** talent delta (every class and tab) |
| `test_talentdelta.py` | unit tests with synthetic data only |

## Change directories

One directory per change, numbered after its issue (`0357-shaman-talents`).
Each directory holds one CSV per DBC it touches, named like the DBC. Every
file starts with an `op` column:

- `insert`: a new row. The columns are the DBC fields, named as in WoWDBDefs /
  the core's `DBCfmt.h`.
- `update`: selected fields of an existing row (`Spell.csv`: `fields`).
- `Spell.csv`: `source=spell_template` means the row is **built from
  `tw_world.spell_template`**, not typed in. The server stays the single
  source of truth for spell numbers and tooltip text.
- `@<id>` in a field: take the value from base row `<id>` at build time (for
  fields our extract does not carry).

Values that live in code, not in `spell_template`, are listed in the change's
`code-values.md` (design #410 §3.4).

> **Format status:** this CSV layout is provisional. The stage-1 schema
> (CL-409, #409 issuecomment-5874199786 point 3: CSV/YAML deltas) is binding
> once it lands; aligning column names is mechanical.

## talentdelta.py

```sh
# layout only (no client, no database)
python3 ops/clientpatch/talentdelta.py --change ops/clientpatch/changes/0357-shaman-talents
# plus server sources of a twow-core checkout (migrations, SpecAuraPolicy.h, generator)
python3 ops/clientpatch/talentdelta.py --change ops/clientpatch/changes/0357-shaman-talents \
    --core core --class 7
# tests
python3 -m unittest ops/clientpatch/test_talentdelta.py
```

**Layout** (errors):
- grid 7×4;
- collisions with base or delta talents;
- duplicate talent IDs or rank spells, gaps in a rank chain;
- unknown, cross-tab or later-tier prerequisites, or a prerequisite rank above its maximum;
- diagonal arrows (the 1.12 talent frame draws only straight down or sideways);
- a new talent placed on an existing arrow.

An arrow that passes over another talent is a **warning**: legal data, but it
looks wrong in the client.

**Server** (`--core`, read-only, no database):
- every rank spell and every `Spell.csv` insert is created by a migration;
- talents whose ranks are SpecAura auras carry the same ranks in the same order;
- `--class N`: the delta's talent IDs equal `STAGE2_TALENTS[N]` of `build_premade_specs.py`;
- `SkillRaceClassInfo.csv` rows equal `skill_race_class_info_mod` rows.

**Limits:**
- Base cells come from the change's `base-cells.csv` (IDs and positions only), read
  from the client once by OB-20. A new client base means reading it again.
- Rank counts of base talents are unknown here, so prerequisite ranks of base
  talents are not checked.
- The check against a live database belongs to the stage-1 consistency check.

**Extending:** a new talent change needs `Talent.csv` and `base-cells.csv` for the
tabs it touches; nothing in the tool is class-specific.
