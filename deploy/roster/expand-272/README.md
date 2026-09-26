# Roster plan 272 (ordinals 137–272), twow-repo#366

**Planning data only.** Nothing here writes to a database, changes the active roster
version, or is wired into `make`, `db-init.sh` or Helm. Activating it (EXPAND 3 → 4, reset of
137–272, V4 profession gate for 272, renames) is a separate, individually approved
maintenance operation after the Ä10 gate (see #366 for the hard prerequisites).

## Files

| File | Content |
|---|---|
| `v4-272-roster-plan.csv` | 272 rows, same columns as `../v4-136-profession-prefix.csv`; rows 1–136 are that prefix byte for byte |
| `select_roster_v4_272.py` | deterministic generator (stdlib only) |

## Inputs and reproduction

- Prefix: `deploy/roster/v4-136-profession-prefix.csv`, SHA-256 `51F0559A…EC39`.
- Free RNDBOT pool: read-only snapshot of all RNDBOT characters not in the active roster
  (`guid, account, name, race, class, gender, level`, ordered by guid), taken 2026-09-26,
  4364 rows, SHA-256 `8EB3F99417F7A7E12A8D8845270F6EF38A97B24304039B2BF2639D34104E8183`,
  stored at `Y:\backup twwow\workspace-relocation-20260902\evidence\ws-60\ob40-366-roster-272-selection\free-pool-snapshot.tsv`.
  The hash is also in every new row (`source_candidate_hash`).

```sh
python3 select_roster_v4_272.py --prefix ../v4-136-profession-prefix.csv \
    --pool free-pool-snapshot.tsv --out v4-272-roster-plan.csv
```

Same inputs give the same output (run twice: SHA-256 identical). Candidates are taken by
`(level, guid)`; all 136 selected characters are level 1.

## What the plan contains (owner decisions D-A..D-C, 2026-09-26)

| | New 137–272 | All 272 |
|---|---|---|
| Tank / healer / DPS | 43 / 21 / 72 | **54 (19.9 %)** / 43 / 175 (prefix ferals counted as cat) |
| Alliance / Horde | 64 / 72 | 136 / 136 |

New classes: warrior 26 (all protection), paladin 19 (13 protection, 4 holy, 2 retribution),
druid 10 (**4 bear**, night elf + tauren, one per gender, 2 restoration, 2 balance, 2 feral), priest 14,
shaman 11, hunter 15, rogue 15, mage 14, warlock 12.

New professions: Mining/Blacksmithing 33 (warriors, paladins), Mining/Engineering 27
(hunters, rogues), Herbalism/Alchemy 29 (mages, warlocks, priests), Mining/Jewelcrafting 22,
Herbalism/Mining 22 (double gatherers: druids, shamans, rogues), Tailoring/Enchanting 3.

## Known gaps before activation

- `talent_path = bear` needs premade path 11.3 in core (#308).
- `Herbalism/Mining` has no `ProfessionPair` value yet (core, OB-10); Mining/Jewelcrafting
  depends on the bot AI supporting Turtle jewelcrafting.
- `name` is the current character name; the creative names are a separate owner review.
- Variant "4 bears" (one per race × gender): 26 warrior tanks + 4 bears instead of 28 + 2; tank share, factions and profession totals unchanged.
