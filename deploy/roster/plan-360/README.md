# Roster waves 180 and 360, race-balanced (twow-repo#366, plan v3)

**Owner decisions (2026-09-27, via OB-00, recorded in #366/#319):**
- Final target per faction 20 tanks / 40 healers / 120 DPS = 180, 360 in total.
- **Wave 1** comes with train 7, without waiting for the 7-day gate: 10/20/60 per faction =
  180 in total.
  - The live 154 get +26 DPS; the new pairs are used right away (variant B).
  - About 4 human bots are swapped (REPLACE), so both factions have exact race balance.
- **Wave 2 (→ 360)** follows once wave 1 demonstrably runs well (tick budget, 0 lost bots, no
  loops, interim analysis) and the owner gives the go.
- **Tank pool:** every tank class takes 20 % of the faction's tanks: bear, warrior, paladin
  (incl. undead paladin), rogue tank (4.3), shaman tank (7.3, incl. dwarf shaman).
- **Diversity cap:** about 2 % per race × class × role, so no "11 orc shaman healers".
  Healers go to races with several healer classes.

**This directory holds planning and tooling only.** The live plan (`plan-180`: GUIDs, names,
requests) is generated in the window after the factory run, from the pool. It is not part of
the train 7 pin.

| File | Content |
|---|---|
| `select_roster_v5.py` | deterministic generator (stdlib only), any size, EXPAND and REPLACE |
| `race-class-catalog.tsv` | the 61 race × class pairs after train 7, with source (`live`, `new-178`, `new-165`) |
| `spec-roles.tsv` | talent path → role; every path is in `../respec/premade-spec-index.tsv` |
| `test_select_roster_v5.py` | 25 tests on the real 154 base with synthetic pools |
| `guild_plan.py` | guild split of a plan (#518): roles per guild, class by class, level bands, stable over stages |
| `../expand-272/make_replace_request.py` | canonical REPLACE request (+ `test_make_replace_request.py`) |
| `../reset-l1`, `../respec` | `--ordinals` now accepts lists such as `89,109,140,149,155-180` |

## Generator rules

**Hard rules, per faction:**
- Races fill up to the even share (size / 5). Nobody shrinks, unless `--replace-excess` swaps
  the excess. It picks from the fullest race × class × role first, then the lowest level
  (`--levels`), then the highest ordinal. The replacement keeps the role.
- The role counts equal `--per-faction`.
- Tank classes fill up to an equal share. A class already above its share keeps its tanks.
- No race × class × role goes above `--cap`, except cells the unchanged base already has above.
- A max-flow check per slot keeps all of this reachable.

**Soft, in this order:**
1. the role furthest behind;
2. the race with the smallest share of that role relative to its room for it (cap × classes
   for the role);
3. the race furthest behind its size;
4. the emptiest class cell;
5. the rarest talent path;
6. the rarest gender.

Professions follow the owner shares. New names are in race style, deterministic and checked
against a name snapshot; the owner "wants to be surprised".

## Wave 1 on the real base (v4/154 → 180, `10,20,60`, cap 4, `--replace-excess`)

| | Races | Roles | Tanks by class |
|---|---|---|---|
| Alliance | human 18 (4 swapped), dwarf 18, night elf 18, gnome 18, high elf 18 | 10/20/60 | warrior 5, paladin 3, bear 2 |
| Horde | orc 18, undead 18, tauren 18, troll 18, goblin 18 | 10/20/60 | warrior 8, bear 2 |

- 26 appended DPS + 4 replacements = **30 changed ordinals**. Without levels the replacements
  are 89, 109, 140 and 149 (human healers from the fullest cells). In the window the live
  levels decide.
- Only one cell is above the cap, and it comes from the base: tauren shaman healer 5.
- Wave 1 adds no tanks, so the tank classes stay as they are. The 20 % rule takes effect with
  wave 2.
- Capacity per faction: 10 dungeon groups (left over 0/10/30), 4 raids of 20 (2/0/8), 1 raid
  of 40 (6/8/36).
- The factory run is only needed for the pairs that wave 1 actually uses (`demand.tsv`,
  `FACTORY` column against the pool snapshot).

## Wave 2 preview (180 → 360, `20,40,120`, cap 7, incl. rogue/shaman tank from twow-core#183)

| | Races | Tanks by class |
|---|---|---|
| Alliance | 36 each | warrior 4, paladin 4, rogue tank 4, shaman tank 4, bear 4 |
| Horde | 36 each | warrior 4, paladin 4, rogue tank 4, shaman tank 4, bear 4 |

- Capacity per faction: 20 dungeon groups (0/20/60), 8 raids of 20 (4/0/16), 3 raids of 40
  (8/4/48). Largest cell 7 (= cap).
- **Exact 20 % tanks (owner decision 2026-09-27):** `--respec-tanks` respecs the surplus
  warrior tanks to a DPS path of their class (preview: Alliance 1, Horde 4). The level stays;
  A6 sets the talent reset, with no L1 reset and no login wave. The race with the most tanks
  of that class goes first, then the highest ordinal. `--respec-out` lists them;
  `A6_ORDINALS` = new + replaced + respecced, `CHANGED_ORDINALS` (reset-l1) = new + replaced.

## Candidates for the new pairs: factory run (DB mutation, individual approval)

The pool has no characters of the new pairs. `RandomPlayerbotFactory::CreateRandomBots` creates
them, but it does not run while `PersistentActiveRoster.Enabled=1`, and it fills only accounts
with fewer than 9 characters. So it runs once with the train 7 image, with overrides for that
start only:

```
AiPlayerbot.PersistentActiveRoster.Enabled = 0
AiPlayerbot.RandomBotAutologin = 0              # no bot logs in
AiPlayerbot.RandomBotAutoCreate = 1
AiPlayerbot.DeleteRandomBotAccounts = 0
AiPlayerbot.RandomBotRandomPassword = 1
AiPlayerbot.RandomBotAccountCount = <current + ceil(sum FACTORY / 9)>
AiPlayerbot.ClassRace.UseFixedClassRaceCounts = 1
AiPlayerbot.ClassRaceProb.<class>.<race> = <FACTORY>   # only pairs with a shortage
```

**Pitfall (OB-30, probe 2026-09-27):** with `UseFixedClassRaceCounts = 1` **every** `ClassRaceProb.<c>.<r>` key in the
rendered config counts as a fixed count (`PlayerbotAIConfig.cpp` ~l.613). The normal profile carries all 48
pairs with defaults (e.g. `1.1 = 40`), so the new accounts would be filled at random from all pairs.
The factory profile must contain **only** the `FACTORY > 0` pairs; remove or comment out every other
`ClassRaceProb.c.r`.

The factory deletes temporary bots and empty rndbot accounts. Pre-check (read-only): no
`bot_delete` event and no `temporary` events.

## Runbook wave 1 (train 7 window)

**Before the window:**
- Train 7 pin with #394 merged; the image contains core#178, #165, #179 and #175 (login waves).
- The profile has `LoginWaveSize = 24`, `LoginWaveIntervalSeconds = 900`.
- **Probe:** steps 1–13 on a live copy in a disposable stack (`--network none`, train 7
  image), with the durations measured. This needs its own owner approval.

**In the window.** `T=deploy/roster`, `C=<live db container>`, `CONF=<runtime mangosd.conf>`.

| # | Who | Step | Check / stop criterion |
|---|---|---|---|
| 1 | OB-00 | stop world/realm/BotBrain | 154 roster bots `online=0`, otherwise STOP |
| 2 | OB-40 | dump + cold backup (as train 6); **player-account list** (accounts with 1–4 characters) + players fingerprint over exactly these accounts | SHA256SUMS; the fingerprint must not depend on the roster (lesson from train 6) |
| 2b | OB-30/OB-40 | migration step of the train 7 image: world `20260927120000` (#165: playercreateinfo 3/7 and 5/2) and the others; **ledger backfill only** for `20260912120000_world` (#288, effect already present, sha1 `37A56611…`); **old event table** `tw_char.ai_playerbot_random_bots` (core#55 `character/20260906120000`): export first (`mariadb-dump … tw_char ai_playerbot_random_bots`, sha256), then apply unchanged; the roster uses `cv_bots` (#366 comment 5857484217) | playercreateinfo 61; old event table 0 duplicates with a UNIQUE key; the `cv_bots` event table checksum unchanged |
| 3 | OB-40 | pre-checks read-only: roster current = 4, `SHA2(ordinal:guid)` = `6de61611…`; no `bot_delete`/`temporary` events; free pool snapshot (`free-pool.sql`), levels snapshot, name snapshot | any deviation → STOP (nothing changed yet) |
| 4 | OB-40 | phase 1 with pool + levels → `demand.tsv` → factory overrides (only `FACTORY > 0` pairs) | counts posted in #366 |
| 5 | OB-00 | **factory run** (overrides), wait for the end of creation, stop, remove overrides | new characters ≈ sum FACTORY; 0 bots online; roster v4 unchanged; players fingerprint unchanged; otherwise STOP → stage 0 |
| 6 | OB-40 | pool snapshot 2 → phase 2 → `v5-180-roster-plan.csv`, `new-names.tsv`, `replace.tsv`, `CHANGED_ORDINALS`; build requests: REPLACE (`make_replace_request.py --expected-current-version 4 --target-count 154`), EXPAND (`make_expand_request.py --ordinals 155-180 --expected-current-version 5`), ROLLBACK (`make_rollback_request.py --expected-current-version 6 --rollback-version 4 --target-count 154`) | hashes posted in #366; OB-30 checks the files |
| 7 | OB-00 | maintenance start 1, `rndbot roster apply <REPLACE>`, stop | `APPLIED_RESTART_REQUIRED`; current = 5, 154 members, members = plan rows 1–154 |
| 8 | OB-00 | maintenance start 2, `rndbot roster apply <EXPAND>`, stop | current = 6, 180 members, snapshot sha = plan 1–180 |
| 9 | OB-40 | A6 `run-respec-roster.sh --csv <plan> --ordinals <CHANGED_ORDINALS> --expect-guid-sha256 <hash> --insert-missing-events --conf $CONF --apply` | `guards=8 asserts_pass=11`, INSERTED 30/30 |
| 10 | OB-40 | rename `run-rename-roster.sh --map new-names.tsv --expect-map-sha256 <sha> --expected 30` | `RENAMED=30`, 9/4 |
| 11 | OB-40 | reset-l1 `run-reset-l1.sh --ordinals <CHANGED_ORDINALS> --expected 30 --expect-guid-sha256 <hash>` | `guards=8 asserts_pass≥23` |
| 11b | OB-40 | **talent reset for the changed shaman paths** (OB-10 SpecAura + premade trims, #357): `../talent-reset/run-talent-reset.sh --class 7 --spec-nos 2,4 --dry-run`, then `--expected <n> --expect-guid-sha256 <h> --apply`. It covers **all** roster shamans on 7.1/7.3, old and new | `guards=4 asserts_pass=4`; only bit 4 is set (no L1, no login wave, the marker is `&6`); players fingerprint unchanged in step 12 |
| 11c | OB-40 | **talent reset for all rogues** (the owner's rogue talent line #367 changes all three trees and adds 4.3 rogue tank): `../talent-reset/run-talent-reset.sh --class 4 --spec-nos 1,2,3,4 --dry-run`, then `--expected <n> --expect-guid-sha256 <h> --apply`. It covers **all** roster rogues, old and new | as 11b: `guards=4 asserts_pass=4`, only bit 4 set, no login wave |
| 12 | OB-40 | final check | 180 members; the 30 at L1 with `at_login & 6`; the other 150 unchanged except bit 4 on the 11b shamans and the 11c rogues; the 4 replaced humans unchanged and outside the roster; players fingerprint = step 2 |
| 13 | OB-00 | normal start | `loaded version 6 with 180`; 150 log in at once, 30 in 2 waves (24 + 6, ≈15 min); `[RosterLoginWave] complete waiting=0`; 180/180 online |

`<hash>` = `run-reset-l1.sh --hash-from-csv <plan> --ordinals <CHANGED_ORDINALS>`.

**Notes from the probe on a live copy (2026-09-27, #366 comment 5858173246):**
- After `rndbot roster apply`, `rndbot roster status` shows `state=INVALID_FAIL_CLOSED version=<old>` until the
  restart. That is **expected** (the new version only loads at the next start) and is not an error.
- The world migrations (step 2b) must run **before** the factory run (step 5). Otherwise the factory
  cannot create dwarf shamans and undead paladins (playercreateinfo is missing).
- Newly created factory characters carry `at_login = 0`, so only reset-l1 opens login waves.
- Measured: factory ≈ 2.5 min, two maintenance applies ≈ 3.5 min, tools (steps 9–11b) < 1 min, normal
  start with waves ≈ 15 min, rollback stage 1 ≈ 3–4 min until everyone is back online.

**Rollback levels:**
- **Stage 0 (before step 7):** abort. The roster is unchanged (v4). Factory characters stay as
  unused pool characters. Normal start with 154.
- **Stage 1 (from step 7 on, any FAIL up to step 13):** `rndbot roster apply <ROLLBACK>` in
  maintenance, then restart. One request brings back v4: the 4 humans return, the 26 new
  stay offline, nobody loses progress. About 6–8 min.
- **Stage 2 (last resort):** cold restore from step 2. It resets the whole database including
  player progress, so only with the owner's decision.

A guard FAIL means nothing changed in that step. An assert FAIL means STOP, and OB-00 decides
stage 1 or 2.

## Runbook wave 2 (180 → 360), delta to wave 1

- Base = the live `v5-180-roster-plan.csv`; `--target 360 --per-faction 20,40,120 --cap 7`.
- Rogue tank (4.3) and shaman tank (7.3) are in `spec-roles.tsv` and `premade-spec-index.tsv` (twow-core#183).
- EXPAND only (`--ordinals 181-360 --expected-current-version 6`); REPLACE only if a race is
  above its share.
- reset-l1 and A6 cover 181–360, so 180 new bots log in in 8 waves of 24 (≈2 h).
- Talent reset (step 11b) again for every class whose premade links or auras changed with that deploy, e.g. rogues `--class 4 --spec-nos <paths>`.
- ROLLBACK to version 6.
- `--respec-tanks --respec-out respec.tsv` (owner decision): A6 runs with `--ordinals <A6_ORDINALS>`;
  reset-l1 only runs with `<CHANGED_ORDINALS>`. Final check: 4 tanks per class and faction;
  the respecced bots keep level, items and profession, and get specNo = new path.

## Stages up to 810 and guilds (#518, owner 04.10.2026)

Roles per guild of 45: **7 tanks / 10 healers / 28 DPS** (owner direction, #366). Each stage adds one
guild per faction (+90 bots): 270, 360, 450, …, 810 (810 instead of 800, so guilds stay complete).

| Option | Effect |
|---|---|
| `--healer-min N` | at least N healers of every healer class of the faction (N = guilds per faction), so every guild can get each healer class (buffs, dispels) |
| `--class-role-max FA:CLS:ROLE:N,…` | hard limit per faction, e.g. `H:2:TANK:<guilds>,H:2:DPS:0` (Horde paladins are undead only); capped tank classes hand their share to the others |
| `--female-share 0.55` | owner: more women than men; new slots are women until the faction reaches the share |
| `--cell-min 1` | owner: every usable race x class x role cell gets at least one bot, so rare pairs (dwarf shaman, undead paladin, druids) appear as healer, tank and DPS |
| `--tank-class-weight 1=2` | owner: warriors may tank clearly more often (twice the share of each other tank class) |

Per stage with g guilds per faction (owner 04.10: variety instead of a paladin limit):
`--target 90g --per-faction 7g,10g,28g --cap max(5,2g) --healer-min g --female-share 0.55 --cell-min 1 --tank-class-weight 1=2`,
with `--base` = the plan of the previous stage.

**Professions (#485/#518):** Skinning/Leatherworking only for leather classes (hunter, rogue, shaman,
druid), but leather classes are not all leatherworkers. Every new bot takes the pair furthest below its
share; ties go to a pair its class prefers, then to the pair its class has least of.

`guild_plan.py plan.csv --per-guild 7,10,28 [--levels guid-level.tsv] [--keep previous-guilds.tsv]` deals
each role class by class (rarest first) over the guilds, then by 5-level band. `--keep` leaves the guilds
of the previous stage unchanged, so a new stage only fills the new guild. This is planning input for
twow-core#281 (guild foundation).

## Reproduction and tests

```sh
python3 select_roster_v5.py --base ../plan-154/v4-154-roster-plan.csv --catalog race-class-catalog.tsv \
    --specs spec-roles.tsv --target 180 --per-faction 10,20,60 --cap 4 --replace-excess \
    --demand demand.tsv --slots-out slots.tsv --summary-out summary.md
python3 -m unittest test_select_roster_v5.py          # 25 tests
python3 -m unittest ../expand-272/test_make_replace_request.py ../expand-272/test_make_expand_request.py
bash ../reset-l1/test-reset-l1-scope.sh --container <disposable> --csv ../plan-154/v4-154-roster-plan.csv --ordinals 101-130
```
