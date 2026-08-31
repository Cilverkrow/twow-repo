# DB-PROFESSION-RIDING-DISCOVERY-01

## Scope and outcome

This was a read-only discovery of the locally effective profession and riding rules. No source, configuration, DBC, client, database row, skill, spell, item, gold value, migration, or existing evidence was changed. Worldserver and Realmd were not started. The already-running local MariaDB instance was queried with `SELECT` statements only.

The requested split cannot be implemented as one data/configuration change:

- Raising the normal-player limit to six is supported by the existing global configuration key in isolation.
- Keeping RNDBOTs strictly at two while normal players receive six requires source enforcement because the global counter is initialized for every `Player`, while the Playerbot factory also assigns skills directly.
- Riding trainer levels and costs are world-database values, but early usable riding also requires a reviewed mount-item decision and consistent Playerbot source changes.
- Advanced riding level 30 versus level 20 remains an operator decision.

## Verified baseline and product identity

- Repository: `C:\TW\ComTW\source`
- Branch: `playerbots-integration-gh`
- HEAD: `42b8a7f742548793910fe8880463aeeb71627fb9`
- HEAD subject: `dc: load recorded routes at runtime, and raise the instance gate`
- MariaDB: `11.4.10-MariaDB`, port 3307, selected character schema `tw_char`
- Runtime config: `C:\TW\ComTW\server\mangosd.conf`, 69,515 bytes, SHA-256 `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D`
- SkillLine DBC: `C:\TW\ComTW\data\dbc\SkillLine.dbc`, SHA-256 `A982CE23D52BE7CAC2A0FFB905F54A2AB35DE65081DDE113D897844ACCC0D23A`
- SOURCE-BASELINE-02-A2 evidence: `C:\TW\ComTW\runbooks\ssc-source-baseline-02a2-20260829-213222`

SOURCE-BASELINE-02-A2 had finished and reported a stable source state: matching recorded/current HEAD, unchanged candidate SQL directories, no SQL writes, no migration, no process-control action, no source/config change, and no build. Its tracker/source parity conclusion was `BLOCKED` because world tracker hashes are recorded as `manual`; that analytical limitation is preserved below and did not indicate an active operation.

The existing Git worktree changes are the previously known LLM/debug and generated-build state, not profession/riding changes. No SQL, migration, database loader, profession source, or riding source file was locally modified during this task.

## A. Local profession definitions

`SpellMgr::IsPrimaryProfessionSkill` classifies every SkillLine DBC entry in category 11 as primary. `IsProfessionSkill` then adds exactly Fishing, Cooking, First Aid, and `SKILL_SURVIVAL2` as non-primary professions. Riding is recognized separately.

| Skill | English | German | Classification | Local learning spells by rank |
| ---: | --- | --- | --- | --- |
| 129 | First Aid | Erste Hilfe | Secondary | 3279 Apprentice; 3280 Journeyman; 7925/19903 Expert; 10847/19902 Artisan |
| 142 | Survival | Überlebenskunst | Secondary custom profession | 1290/46051 Apprentice; 7361/46052 Journeyman; 46055 Expert; 46057 Artisan |
| 164 | Blacksmithing | Schmiedekunst | Primary | 2020, 2021, 3539, 9786 |
| 165 | Leatherworking | Lederverarbeitung | Primary | 2155, 2154, 3812, 10663 |
| 171 | Alchemy | Alchimie | Primary | 2275, 2280, 3465, 11612 |
| 182 | Herbalism | Kräuterkunde | Primary | 2372, 2373, 3571, 11994 |
| 185 | Cooking | Kochkunst | Secondary | 2551; 3412; 2552/19886; 18261/19887 |
| 186 | Mining | Bergbau | Primary | 2581, 2582, 3568, 10249 |
| 197 | Tailoring | Schneiderei | Primary | 3911, 3912, 3913, 12181 |
| 202 | Engineering | Ingenieurskunst | Primary | 4039, 4040, 4041, 12657 |
| 333 | Enchanting | Verzauberkunst | Primary | 7414, 7415, 7416, 13921 |
| 356 | Fishing | Angeln | Secondary | 7733, 7734, 7736/19889, 18249/19890 |
| 393 | Skinning | Kürschnerei | Primary | 8615, 8619, 8620, 10769 |
| 755 | Jewelcrafting | Juwelenschleifen | Primary | 30219, 30223, 30225, 30227 |

The authoritative per-spell trainer level, skill prerequisite, cost range, source table, and offer count are in `profession-definitions.csv`; all 679 concrete trainer/NPC expansions are in `profession-training-offers.csv`. A missing trainer offer for a learning spell is evidence that the rank is acquired by another local path (for example a book), not permission to invent a trainer row.

### Survival and Jewelcrafting

- Hunter class skill 51 is named Survival but is not the profession.
- The custom profession is `SKILL_SURVIVAL2 = 142`. It is explicitly included as a secondary profession and does not consume a primary-profession point. Its trainer ranks are present locally.
- Jewelcrafting 755 exists in the local DBC, spell table, and trainer data and is category 11, therefore primary.
- The classic `MANGOSBOT_ZERO` branch deliberately substitutes Herbalism/Skinning where non-classic builds may choose Jewelcrafting/Mining. Jewelcrafting is locally available to players but is not selected by that classic random-bot factory branch.

## B. Current primary-profession limit and learning paths

### Effective limit

- `C:\TW\ComTW\server\mangosd.conf:833`: `MaxPrimaryTradeSkill = 2`
- `src/game/World.cpp:1135`: loads the same key with default 2.
- `src/game/Objects/Player.cpp:21193-21195`: every `Player` receives the global value in the free-primary-profession counter.
- `src/game/Objects/Player.h:1976-1977`: that counter is the Player update field `PLAYER_CHARACTER_POINTS2`; there is no separate database limit column per account type.
- `src/game/Objects/Player.cpp:5401-5423`: trainer state disables a first-rank primary profession when that counter is zero.
- `src/game/Objects/Player.cpp:4568-4573`: learning a first rank decrements the counter only while it is nonzero.
- `src/game/Objects/Player.cpp:4739-4745`: unlearning increments the counter, capped by the global config.

Actual learned skills and ranks are persisted in `tw_char.character_skills(guid, skill, value, max)`. The configured counter is global to the `Player` class; it has no RNDBOT, normal-player, other-playerbot, or GM discriminator. Actual behavior is classified `MIXED` because Playerbots additionally use direct module-specific skill assignment and GM commands can take administrative learning paths.

### Path analysis

| Path | Local behavior | Limit consequence |
| --- | --- | --- |
| Normal trainer | `NPCHandler.cpp:217,232-253,282-371` calls `GetTrainerSpellState`, checks cost, and casts the learning spell | First-rank primary trainer purchase is blocked at zero free points |
| Character creation/login | `Player.cpp:1012,16842,21193-21195` initializes the counter before spells are added/loaded | Existing skills consume available points while loaded but are not deleted |
| Playerbot creation | `PlayerbotMgr.cpp:2417` initializes the same global counter | A config value of six reaches Playerbot objects too |
| RNDBOT profession factory | `PlayerbotFactory.cpp:3928-3997,4275-4294` selects two primary skills and calls `SetSkill` directly | Direct assignment bypasses trainer/free-point gating |
| RNDBOT refresh | `PlayerbotFactory.cpp:4119-4125` removes factory-listed skills whose value is exactly 1 | Existing independent bot behavior; must be considered before any provisioning test |
| Playerbot trainer AI | Uses `GetTrainerSpellState`; initial profession training is also constrained by bot policy | Normal trainer guard applies, but does not cover direct factory assignment |
| GM `.learn` | `Commands.cpp:892-945` calls `LearnSpell` (or high-rank learning) | No cap rejection at the command handler; counter merely stops decrementing at zero |
| GM all-trainer | `Commands.cpp:859-889` explicitly skips primary first ranks | Does not add a new primary first rank |
| Quest/item/script learning spell | `SpellEffects.cpp:2239-2255` calls `LearnSpell` | Central learning does not reject a first rank solely because free points are zero |
| Direct skill step | `SpellEffects.cpp:2748-2762` calls `SetSkill` | Bypasses trainer point checks |

Consequently, changing the global config to six implements six free slots for normal players but also initializes bots with six. The requested split requires a bot-aware source guard plus module checks. SQL cannot safely enforce a runtime spell-learning policy.

### Existing skills and limit changes

- The limit prevents the ordinary trainer path from learning another first-rank primary profession; it does not remove persisted skills or recipes.
- Raising 2 to 6 does not endanger existing skill values or recipes.
- Lowering 6 back to 2 sets future free slots to zero after two or more loaded professions but does not automatically remove excess professions.
- A rollback from 6 to 2 therefore cannot promise to restore the exact old skill population. Removing skills would be a separate destructive policy and is not recommended implicitly.
- The Playerbot factory's value-1 cleanup is unrelated to changing the global limit and must be controlled in any future bot test.

## C. Character inventory

The classification uses only the local, exact username pattern `RNDBOT0` through `RNDBOT499`; account names are not exported. Four character records have no matching login-account row. They are conservatively included in the `PLAYER` export because they are not proven RNDBOTs.

| Account type | Characters | 0 primary | 1 primary | 2 primary | >2 | >6 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| RNDBOT | 4,500 | 4,491 | 5 | 4 | 0 | 0 |
| Player/non-RNDBOT | 9 | 8 | 1 | 0 | 0 | 0 |

No character currently has skill 762 (generic Riding) in `character_skills`.

Observed profession-bearing RNDBOT rows are still sparse because bot levels are 1–9. Current RNDBOT primary-skill counts are: Blacksmithing 1, Leatherworking 1, Alchemy 2, Herbalism 5, Mining 3, and Skinning 1. Secondary counts are First Aid 5, Survival 4, Cooking 3, and Fishing 4. Some characters hold both paired skills; therefore per-skill counts are not character totals.

Detailed GUID/race/class/level/count/skill-value exports:

- `rndbot-professions.csv` — 4,500 rows
- `player-professions.csv` — 9 rows
- `profession-distribution.csv`
- `profession-skill-distribution.csv`

No account username, password, session key, email address, IP address, or other login credential is present in these files.

## D. Local riding skills, trainers, and hard-coded paths

### Spells and resulting skills

| Trainer spell | Triggered spell | Result | Current trainer requirement | Current cost |
| ---: | ---: | --- | --- | ---: |
| 33389 Apprentice Riding | 33388 Riding | Skill 762 step 1, cap 75 | Level 40, no prior skill | 900,000 copper (90g) |
| 33392 Journeyman Riding | 33391 Riding | Skill 762 step 2, cap 150 | Level 60, skill 762, required value 0 | 9,000,000 copper (900g) |

The actual skill spells have local `spellLevel=1`. The trainer wrappers carry effect 44 (skill step) and trigger 33388/33391. `Spell::EffectLearnSkill` computes maximum skill as step × 75. Trainer level and price are enforced from `npc_trainer_template`, not from those spell levels.

The copper interpretation is local and explicit: `COPPER=1`, `SILVER=100`, `GOLD=10000` in `src/shared/Common.h:168-170`; `NPCHandler.cpp:333-371` compares and deducts `trainer_spell->spellCost` directly.

### Trainers

Template 1 contains exactly two riding rows. Ten trainer creatures use it, one for each local race value 1–10:

Kar Stormsinger, Randal Hunter, Kildar, Jartsam, Ultham Ironhorn, Velma Warnam, Xar'Ti, Binjy Featherwhistle, Gaxx Speedcrank, and Chaddus Suncarrier.

Every one exposes the same level, skill, and cost because all share template 1. No faction-specific price/level deviation exists in the current trainer data. Exact creature entry, faction, race, class, and both offer rows are in `riding-trainers.csv`.

### Playerbot path

Playerbots do not rely exclusively on the normal trainer path:

- `PlayerbotFactory.cpp:4133-4161`: classic bots receive skill 75 at level 40 and 150 at level 60 by direct `SetSkill`.
- `MountValues.cpp:356-368`: classic mount buying is rejected below level 40.
- `BudgetValues.cpp:251-285`: classic basic/epic levels are 40/60 and budgets are 40g/1000g.
- `RandomPlayerbotMgr.cpp:4437-4445`: the riding-skill hotfix does nothing below level 20.

Basic riding at level 5 and either advanced variant therefore require a coordinated Playerbot source change. A database-only update would affect normal trainer availability but not produce consistent bot behavior.

## E. Mount items and prices

The scan found 31 item rows whose first item spell applies local mounted aura 78. They include deprecated/test objects, old race-specific riding skills, no-skill legacy objects, and generic skill-762 objects. The complete inventory is `mount-items.csv`; no current `npc_vendor` or `npc_vendor_template` link was found for these 31 rows, so a current merchant must not be inferred from item names alone.

The relevant generic skill-762 groups are:

| Items | Character level | Skill/rank | Mounted speed | Item buy price |
| ---: | ---: | --- | ---: | ---: |
| 9 | 40 | 762 / 75 | +60% | 100,000 copper (10g) |
| 2 | 60 | 762 / 150 | +100% | 1,000,000 copper (100g) |

Training cost and item buy price are independent fields. Changing trainer rows does not alter mount prices.

At levels 5, 20, or 30, a character could learn the lowered riding skill but could not use the generic mount items because their own required levels remain 40/60. Accordingly:

1. **Training cost only:** cheapest and narrowest; early skill exists but current generic mounts remain unusable.
2. **Training cost plus selected mount levels:** enables actual early riding; requires an explicit allowlist of non-deprecated items and a separate migration.
3. **Training cost, mount levels, and item prices:** technically possible but not authorized or implied. Purchase-price policy remains undecided.

## F. Target comparison and technical ownership

| Target | Database | Config | Source | Client/DBC | Mount items | Decision |
| --- | --- | --- | --- | --- | --- | --- |
| Players 6, RNDBOTs 2 | No profession DDL/DML | Set global player value to 6 after source guard | RNDBOT-aware central/module enforcement required | No | n/a | No variant choice |
| Basic riding L5, 5s (500 copper) | Update `(entry=1, spell=33389)` | None | Playerbot L5 paths required | No | Required for usable early riding | Select items separately |
| Advanced riding L30, 1g (10,000 copper) | Update `(1,33392)` | None | Playerbot L30 paths required | No | Required for usable L30 riding | Variant A |
| Advanced riding L20, 1g (10,000 copper) | Update `(1,33392)` | None | Playerbot L20 paths required | No | Required for usable L20 riding | Variant B |

Potential progression and bypass concerns:

- Early riding increases travel efficiency dramatically and may bypass intended travel, escort, danger, or economy pacing.
- Trainer reputation discounts still apply to the proposed low prices.
- Existing direct spell/skill assignment paths can bypass trainer price and level checks.
- Bots currently budget and assign riding separately; inconsistent constants can grant free skills or prevent use/purchase.
- Lowering item levels broadly could expose deprecated/test, faction, or race-specific items. Use an explicit reviewed allowlist.
- Existing characters keep already learned skills after rollback unless a separate destructive operation is approved.

## G. Provenance, tracker, and migration analysis

### Provenance

- Global profession limit source and checks trace to commit `818b3861f87178a09a3d35aea1321cd39f3a0f12` (`Initial Upload`, 2025-12-16).
- Playerbot profession and riding factory logic traces to `0af2567767de69a819287acaab4c5c947cc1e04c` (`checkpoint: cmangos/playerbots port grafted onto Penqle/tortoise-wow 1181dev`, authored 2026-05-10).
- The current riding trainer base rows were introduced into `sql/base/tw_world_npc_trainer_template.sql` by commit `e1a48b4442d4d6dc369408cbc094087377cb746f` (`Initial 1.18.1-7272 spell implimentation`, 2026-05-03).
- No committed SQL migration outside the base file references the exact `(1,33389,900000,0,0,40)` or `(1,33392,9000000,762,0,60)` row.
- Live rows exactly match the current base rows. This proves current-state parity, not how or when the installation imported them.

### Trackers

- `tw_char.migrations`: four reviewed cryptographic hashes.
- `tw_logon.migrations`: zero rows and no `Module` column.
- `tw_world.migrations`: 146 rows, all recorded with `Hash='manual'`, last name `20260821203635_world`.

The world tracker therefore cannot cryptographically bind the live riding rows to particular SQL bytes. This is a provenance limitation, not evidence of a live mismatch. A new migration is possible and should be forward-only, immutable, hashed externally, state-preconditioned, verified before registration, and never retrofitted into the base file.

The separate plan is `proposed-migration-plan.md`. It includes current/target values, unique keys, exact preconditions, post-validation, rollback values, repeat-execution hazards, source/config sequencing, and the unresolved mount-item and advanced-level decisions.

## Source/config/SQL/DBC/client path inventory

### Core and configuration

- `C:\TW\ComTW\server\mangosd.conf:833`
- `src/mangosd/mangosd.conf.dist.in:831-833`
- `src/game/World.cpp:1135`
- `src/game/Objects/Player.cpp:1012,4568-4573,4739-4745,5401-5423,16842,21193-21195`
- `src/game/Objects/Player.h:1976-1977`
- `src/game/Handlers/NPCHandler.cpp:117-159,210-253,282-371`
- `src/game/Spells/SpellMgr.h:264-283`
- `src/game/Spells/SpellMgr.cpp:1303-1347`
- `src/game/Spells/SpellEffects.cpp:2239-2255,2748-2762`
- `src/game/Commands/Commands.cpp:662-739,850-947,13092+`
- `src/game/SharedDefines.h:1149-1245`
- `src/game/Spells/SpellAuraDefines.h:170,216`
- `src/shared/Common.h:168-170`

### Playerbot

- `src/modules/PlayerBots/playerbot/PlayerbotFactory.cpp:32-50,3921-3997,4119-4161,4275-4294`
- `src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp:2417`
- `src/modules/PlayerBots/playerbot/RandomPlayerbotMgr.cpp:4437-4445`
- `src/modules/PlayerBots/playerbot/strategy/values/MountValues.cpp:289-379`
- `src/modules/PlayerBots/playerbot/strategy/values/BudgetValues.cpp:251-285`
- `src/modules/PlayerBots/playerbot/strategy/values/TrainerValues.cpp:131-148`
- `src/modules/PlayerBots/playerbot/strategy/actions/TrainerAction.cpp:244-250`

### Database and migration sources

- `sql/base/tw_world_npc_trainer_template.sql`
- `sql/base/tw_world_spell_template.sql`
- `sql/base/tw_world_item_template.sql`
- `sql/base/tw_world_creature_template.sql`
- `sql/database_updates/world/` (current future forward world-migration location; root-level files are legacy history)
- Live tables: `tw_world.npc_trainer`, `npc_trainer_template`, `creature_template`, `spell_template`, `item_template`, `npc_vendor`, `npc_vendor_template`; `tw_char.characters`, `character_skills`; `tw_logon.account`

### DBC/client

- `C:\TW\ComTW\data\dbc\SkillLine.dbc`
- The server sends trainer level/state/cost from database-backed trainer data and item requirements from server item templates. No client patch is required for the proposed server-side values. No DBC/client file was changed.

## Evidence files

- `read-only-queries.sql` — repeatable SELECT-only queries
- `profession-skillline-dbc.csv` — local English/German SkillLine classification
- `profession-definitions.csv` — all local rank spells and trainer ranges
- `profession-training-offers.csv` — 679 expanded profession trainer offers
- `rndbot-professions.csv` — 4,500 character rows
- `player-professions.csv` — 9 character rows
- `profession-distribution.csv`
- `profession-skill-distribution.csv`
- `riding-skills.csv`
- `riding-trainers.csv`
- `mount-items.csv`
- `migration-trackers.csv`
- `current-target-ownership.csv`
- `proposed-migration-plan.md`
- `SHA256SUMS.txt`

The SQL evidence was executed once through the MariaDB client for syntax/readability validation: 15 top-level `SELECT` statements, zero forbidden write-statement tokens, client exit code 0, and empty stderr.

## Final operational state

- The pre-existing MariaDB process remained running as PID 31724 from `C:\TW\ComTW\DB\bin\mysqld.exe`; it was neither started nor stopped by this task.
- Port 3307 remained owned by PID 31724 for the permitted read-only queries.
- `mangosd` processes: 0.
- `realmd` processes: 0.
- Matching running Windows services: 0.
- Port 8090 listeners: 0.
- No bot/player login was triggered.
- No build, migration, rollback, dump, Honor operation, launcher, or shutdown helper was invoked.

## Required result fields

```text
PROFESSION_LIMIT_DISCOVERY_RESULT=PASS
CURRENT_PRIMARY_PROFESSION_LIMIT=2
CURRENT_LIMIT_SCOPE=MIXED
PLAYER_LIMIT_SIX_CONFIG_ONLY=YES
SEPARATE_BOT_LIMIT_TWO_SUPPORTED=NO
BOT_LIMIT_CORE_CHANGE_REQUIRED=YES
PLAYER_LIMIT_CORE_CHANGE_REQUIRED=NO
EXISTING_BOTS_OVER_TWO=0
EXISTING_PLAYERS_OVER_TWO=0
EXISTING_PLAYERS_OVER_SIX=0
SECONDARY_PROFESSIONS_EXCLUDED=YES

RIDING_DISCOVERY_RESULT=PASS
CURRENT_BASIC_RIDING_LEVEL=40
CURRENT_BASIC_RIDING_COST=900000 copper
CURRENT_ADVANCED_RIDING_LEVEL=60
CURRENT_ADVANCED_RIDING_COST=9000000 copper
BASIC_RIDING_LEVEL_5_DB_ONLY=NO
ADVANCED_RIDING_LEVEL_20_DB_ONLY=NO
ADVANCED_RIDING_LEVEL_30_DB_ONLY=NO
CLIENT_CHANGE_REQUIRED=NO
MOUNT_ITEM_CHANGE_REQUIRED=YES
BOT_RIDING_PATH_SEPARATE=YES

MIGRATION_ANALYSIS_RESULT=PASS
FORWARD_MIGRATION_POSSIBLE=YES
ROLLBACK_DEFINED=YES
SOURCE_CHANGE_REQUIRED=YES
CONFIG_CHANGE_REQUIRED=YES
DATABASE_CHANGE_REQUIRED=YES
OPERATOR_DECISION_REQUIRED=YES
```

`PLAYER_LIMIT_SIX_CONFIG_ONLY=YES` means only that the normal global Player limit can be raised by the existing config key. It must not be applied alone for the requested split: the combined target still requires RNDBOT source enforcement before the global value becomes six.
