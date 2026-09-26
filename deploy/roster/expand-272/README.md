# Roster plan 272, twow-repo#366 (version 2)

**Planning data only.** Nothing here writes to a database, changes the active roster
version, or is wired into `make`, `db-init.sh` or Helm. Activating it (EXPAND 3 → 4, respec
and profession change of the existing 136, reset of 137–272, specNo and V4 profession gate
for 272, renames) is a separate, individually approved maintenance operation after the Ä10
gate (see #366 for the hard prerequisites).

## Files

| File | Content |
|---|---|
| `v4-272-roster-plan.csv` | 272 rows, same columns as `../v4-136-profession-prefix.csv` |
| `existing-136-diff.csv` | what changes for ordinals 1–136: old/new talent path, role, profession pair |
| `new-136-names.tsv` | owner-approved creative names for ordinals 137–272 (`run-rename-roster.sh` format) |
| `select_roster_v4_272.py` | deterministic generator (stdlib only) |
| `make_expand_request.py`, `test_make_expand_request.py`, `testdata/` | EXPAND request generator and its golden test (A2, below) |

## Inputs and reproduction

- Prefix: `deploy/roster/v4-136-profession-prefix.csv`, SHA-256 `51F0559A…EC39`.
- Free RNDBOT pool: read-only snapshot of all RNDBOT characters not in the active roster
  (`guid, account, name, race, class, gender, level`, ordered by guid), taken 2026-09-26,
  4364 rows, SHA-256 `8EB3F99417F7A7E12A8D8845270F6EF38A97B24304039B2BF2639D34104E8183`,
  stored at `Y:\backup twwow\workspace-relocation-20260902\evidence\ws-60\ob40-366-roster-272-selection\free-pool-snapshot.tsv`.
  The hash is also in every new row (`source_candidate_hash`).

```sh
python3 select_roster_v4_272.py --prefix ../v4-136-profession-prefix.csv \
    --pool free-pool-snapshot.tsv --out v4-272-roster-plan.csv --diff existing-136-diff.csv
```

Same inputs give the same output (run twice: SHA-256 identical). New candidates are taken
by `(level, guid)`; all 136 selected characters are level 1.

## What the plan contains (owner decisions #366 part 3, 2026-09-26)

The whole 272 is planned from scratch. **Always more healers than tanks.**

| Role | Total | Alliance | Horde |
|---|---|---|---|
| Tank | **40** (14.7 %) | 20: warrior 10, paladin 6, bear 4 | 20: warrior 16, bear 4 |
| Healer | **60** (22.1 %) | 30: priest 16, paladin 10, druid 4 | 30: priest 12, shaman 14, druid 4 |
| DPS | **172** | 86 | 86 |

- **8 bears:** night elf and tauren, each gender twice.
- **At least one warrior tank per race:** all 10 races covered.
- **Existing 136** keep class, race, gender, name and level. A bot keeps its talent path
  whenever that path still has room; only **13 need a respec** (7 warriors DPS → protection,
  6 druids → bear), **75 get a new profession pair**, 60 stay unchanged
  (`existing-136-diff.csv`).
- **Professions over all 272** (owner table): Herbalism/Alchemy 54, Tailoring/Enchanting 49,
  Skinning/Leatherworking 49, Mining/Blacksmithing 33, Mining/Engineering 27,
  Mining/Jewelcrafting 22, Herbalism/Mining (double gatherers) 38. Assigned by class fit:
  blacksmithing to warriors, leatherworking to rogues/druids/hunters/shamans, engineering to
  hunters/rogues, tailoring/enchanting to mages/priests/warlocks, alchemy to
  priests/paladins/druids/shamans, jewelcrafting to paladins/priests/shamans.
- **Names** of the 137–272 bots: `new-136-names.tsv`, approved by the owner (adapted to this
  mix in the same style); letters only, 2–12 characters, no collision with `characters`,
  `ai_playerbot_names` or `creature_template`.

## Known gaps before activation

- `talent_path = bear` needs premade path 11.3 in core (#308).
- `Herbalism/Mining` = ProfessionPair 7 (twow-core#161); the V4 gate must accept 1–7.
- Respec and profession change of existing bots need their own guarded tool (#366 A6).

## EXPAND request (#366 A2)

`make_expand_request.py` writes the canonical `ssc-rndbot-admin-request-v1` EXPAND
request for a CSV range, byte for byte as the core's `SerializeAdminRequest()` produces it
(LF, UTF-8 without BOM, unpadded base64url actor/reason, 10-digit `add` rows in ordinal
order). It touches no database; the file is applied later in maintenance mode with the
local console command `rndbot roster apply <absolute-path>` (ADR-0011).

```sh
python3 make_expand_request.py --csv v4-272-roster-plan.csv --ordinals 137-272 \
    --expected-current-version 3 --actor <who> --reason <why> --out request.txt
```

It prints `operation_id` (a fresh UUIDv4 unless `--operation-id` is given) and
`request_sha256`; the approval names that hash, and replaying the same operation id with
other bytes fails closed in the core.

`test_make_expand_request.py` (stdlib unittest) rebuilds the request stored with roster
version 3 in the live database (`testdata/v3-expand-request.golden.txt`, request_sha256
`6f0c1971…e88d`, the 2 → 3 expansion of ordinals 69–136) byte for byte, checks the shape of
the 272 request and rejects bad operation ids, duplicate/zero GUIDs, an empty actor and a
range beyond the CSV.
