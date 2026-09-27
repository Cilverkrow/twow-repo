# Roster 308, race-balanced (twow-repo#366)

**Planning only.** No live step before the Ä10 gate (7 days with 154, earliest
2026-10-03 23:13 UTC), the gate report and the owner's approval. Target: the doubling to 308
comes with train 7.

Owner requirements (2026-09-27, via OB-00):
- every race about equally often (±1 per faction);
- spread evenly over the valid race × class × talent tree combinations;
- scalable (154/308/…);
- the new pairs are included: twow-core#178 (orc mage, dwarf mage/warlock, troll warlock,
  undead hunter, gnome hunter, tauren priest) and twow-core#165/#179 (dwarf shaman, undead
  paladin).

Existing rules stay: role ratio, bears per race × gender, factions 50/50, profession pairs.

**Plan v2 (owner, 2026-09-27, via OB-00):** "11 orc shaman healers" is exactly what the owner
does not want. New diversity cap: no race × class × role above `--cap` (6 for 308, about 2 %
of the roster). Healers go mainly to races with several healer classes. Race totals stay ±1;
the orcs fill up with tanks and DPS.

| File | Content |
|---|---|
| `select_roster_v5.py` | deterministic generator (stdlib only), any size |
| `race-class-catalog.tsv` | the 61 race × class pairs a roster bot may have after train 7 |
| `spec-roles.tsv` | talent path → role; every path must be in `../respec/premade-spec-index.tsv` |
| `test_select_roster_v5.py` | 15 tests on the real 154 base with synthetic pools |

## How the generator decides

Rows 1..K of the current plan stay byte-identical (EXPAND keeps the prefix). For the new rows,
per faction:

**Hard rules:**
1. Race size = faction size / 5, ±1. The +1 goes to the races that already have the most bots.
   If a race is already above its target, the generator stops: only a REPLACE could fix that.
2. Tanks / healers / DPS = `--per-faction`.
3. Bears = `--bears-per-race-gender` for every race × gender with druids.
4. No race × class × role above `--cap` over the whole roster (base included).
5. Every slot must keep rules 1–4 reachable: a max-flow check race → class/role cell (free
   capacity) → role.

**Soft, in this order:**
1. the role furthest behind;
2. the race with the smallest share of that role **relative to its room for it** (cap × number
   of its classes that can play the role). Tauren (priest, shaman, druid) therefore carry about
   three times the healers of the orc (shaman only);
3. the race furthest behind its size;
4. the emptiest class cell;
5. the rarest talent path;
6. the rarest gender.

Professions follow the owner shares over the whole roster (HA 20 %, TE 18 %, SL 18 %,
MB 12 %, ME 10 %, MJ 8 %, HM 14 %). The new ordinals alternate Alliance and Horde.
`--summary-out` writes the result per race and the group capacity table.

**Phase 1** (`--demand`, no pool needed) writes the candidate demand per race × class ×
gender. With `--pool` it also writes the shortage and the `FACTORY` count: twice the larger
gender gap plus four, because the factory picks the gender at random. **Phase 2** (`--pool`,
`--out`, `--names-out`) fills every slot from the free pool: same race and class, same gender
first, lowest (level, guid). A missing pair stops with "run the factory first".

New names follow the style of the approved lists (compound names per race, female/male
endings). They are deterministic for `--name-seed` and never repeat a name from
`--taken-names`. The rename tool checks the name format and uniqueness against the database
again. The owner "wants to be surprised": the names are not approved one by one.

## Result on the real base, plan v2 (v4/154 → 308, `20,40,94`, 2 bears per race × gender, cap 6)

**Is the cap feasible with races ±1?** Tested on the real base:

| Cap | Result |
|---|---|
| 3 | impossible: 2 bears per race × gender already means 4 druid tanks per race |
| 4 | impossible: Alliance races ±1 + 40 healers do not fit |
| **5** | **feasible** (orc healers 5, tauren 15) |
| **6** | **feasible**, recommended (orc healers 6, tauren 13, largest cell 6) |

For other sizes, scale the cap at about 2 % of the roster (462 → 9, tested).

**Cap 6 per race:**

| Alliance | Bots | T / H / D | | Horde | Bots | T / H / D |
|---|---|---|---|---|---|---|
| Human | 31 | 4 / 8 / 19 | | Orc | 31 | 4 / **6** / 21 |
| Dwarf | 31 | 3 / 10 / 18 | | Undead | 31 | 4 / 10 / 17 |
| Night elf | 31 | 5 / 12 / 14 | | Tauren | 31 | 5 / 13 / 13 |
| Gnome | 30 | 4 / 0 / 26 | | Troll | 31 | 2 / 11 / 18 |
| High elf | 31 | 4 / 10 / 17 | | Goblin | 30 | 5 / 0 / 25 |

Every new pair gets bots, 8 bears, no race × class × role above 6.

**Group capacity per faction (20 tanks / 40 healers / 94 DPS)**, the proof for the owner:

| At the same time | Template T/H/D | Full groups | Left over T/H/D |
|---|---|---|---|
| 5-man dungeon | 1/1/3 | **20** | 0/20/34 |
| 20-man raid (ZG/AQ20) | 2/5/13 | **7** | 6/5/3 |
| 40-man raid | 4/12/24 | **3** | 8/4/22 |

The 20-man template (2/5/13) is an assumption; the 40-man template comes from OB-00/the owner.

## Where the new pairs' candidates come from: factory run (DB mutation, individual approval)

The free pool has no characters of the new pairs yet. `RandomPlayerbotFactory::CreateRandomBots`
(twow-core) creates them, but:
- it does not run while `PersistentActiveRoster.Enabled=1`;
- it fills only accounts with fewer than 9 characters.

Therefore run it **once, in the window, with the train 7 image**, using these overrides only
for that start:

```
AiPlayerbot.PersistentActiveRoster.Enabled = 0
AiPlayerbot.RandomBotAutologin = 0              # no bot logs in
AiPlayerbot.RandomBotAutoCreate = 1
AiPlayerbot.DeleteRandomBotAccounts = 0
AiPlayerbot.RandomBotRandomPassword = 1
AiPlayerbot.RandomBotAccountCount = <current + ceil(sum FACTORY / 9)>
AiPlayerbot.ClassRace.UseFixedClassRaceCounts = 1
AiPlayerbot.ClassRaceProb.<class>.<race> = <FACTORY>   # one line per pair with a shortage
```

**Pre-checks (read-only):**
- no `bot_delete` event and no `temporary` events in the event store. The factory deletes
  temporary bots and empty rndbot accounts.
- the roster tables before and after are identical.

This is a **DB mutation** (new accounts and characters) and needs its own individual approval,
separate from the roster steps. A hand-written SQL creation step was rejected: it would have to
reproduce spells, items, skills and action bars.

## Runbook, window 154 → 308 (train 7)

**Prerequisites:**
- Ä10 gate PASS and owner approval.
- Train 7 image with core#178, #165, #179 and #175 (login waves).
- The new shaman/rogue tank paths from OB-10 are in `premade-spec-index.tsv` and
  `spec-roles.tsv` (then run phase 1 again).
- The profile has `LoginWaveSize = 24`, `LoginWaveIntervalSeconds = 900`.

**Before the window:**
1. Take a free pool snapshot (read-only), run phase 1 and fix the FACTORY counts. Post the
   hashes in #366.
2. **Dry run** of steps 3–10 on a live copy in a disposable stack (`--network none`, train 7
   image). This needs its own approval.

**In the window:**

| Step | Who | What | Check |
|---|---|---|---|
| 3 | OB-00 | stop world/realm/BotBrain | 154 roster bots `online = 0` |
| 4 | OB-40 | dump + cold backup (as train 6); players fingerprint | SHA256SUMS |
| 5 | OB-00/OB-40 | **factory run** (overrides above), wait for the end of creation, stop, remove overrides | new characters = sum FACTORY ± gender; 0 logins; roster v4 unchanged (`6de61611…`) |
| 6 | OB-40 | pool snapshot 2 (read-only) → phase 2 → plan CSV + names TSV; `../expand-272/make_expand_request.py --ordinals 155-308 --expected-current-version 4`; `make_rollback_request.py` v5 → v4 | hashes posted in #366 |
| 7 | OB-00 | maintenance start, `rndbot roster apply <request>`, stop | `APPLIED_RESTART_REQUIRED` |
| 8 | OB-40 | checkpoint | current = 5, 308 members, members 1–154 = v4, request sha |
| 9 | OB-40 | A6 `--ordinals 155-308 --insert-missing-events`; rename `--expected 154`; reset-l1 `--ordinals 155-308` | 8/11, 9/4, 8/23 |
| 10 | OB-40 | players fingerprint with a **fixed** exclusion: the 308 v5 GUIDs + every GUID created by the factory | identical to step 4 (lesson from train 6) |
| 11 | OB-00 | normal start | `[PersistentRoster] loaded version 5 with 308`; 154 old bots at once, 154 new in 7 waves; `[RosterLoginWave] complete waiting=0`; 308/308 online |

Only the new ordinals get the L1 reset flag, so only they log in in waves. The 154 existing
bots keep their progress and log in at once.

**Rollback:**
- **Stage 1:** ROLLBACK v5 → v4. Bots 155–308 stay offline, no progress lost.
- **Stage 2:** cold restore from step 4. Last resort only; it also resets player progress.

## Reproduction and tests

```sh
python3 select_roster_v5.py --base ../plan-154/v4-154-roster-plan.csv --catalog race-class-catalog.tsv \
    --specs spec-roles.tsv --target 308 --per-faction 20,40,94 --bears-per-race-gender 2 --cap 6 \
    --demand demand.tsv --slots-out slots.tsv --summary-out summary.md
python3 -m unittest test_select_roster_v5.py
```

Phase 1 on the real base (plan v2, cap 6): `demand_sha256 = 38DCB3EE18CB10C658E4B11DE3E2C9A204696C13A94D2D4971D67D3B5B19D45C`.
