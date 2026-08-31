# PLAYERBOT-CLASS-RACE-MATRIX-01

Status: `CLASS_RACE_MATRIX_RESULT=PASS`

## Scope and integrity

- Active config: `C:\TW\ComTW\server\aiplayerbot.conf`
- Active config SHA-256 before/after: `490957B3D3AF762E8A8FB07F151419E4375F6E38E4C208736A6CA12D38C561FF`
- Active config last-write UTC: `2026-08-29T16:04:14.8193927Z`
- Extracted complete ClassRaceProb section SHA-256: `8E1443ACCFF84FBE97F004BF530BC953F862EF3D3A480D0F5961F129C1DB1392`
- The active config and its snapshot are byte-identical (283717 bytes).
- No config, bot, schema, or database row was changed. All analytical SQL statements were `SELECT` statements.

The active fixed-count switch is commented and defaults to disabled. The active online target is 50 (`MinRandomBots=50`, `MaxRandomBots=50`), the account prefix is `RNDBOT`, and the configured account range is `RNDBOT0` through `RNDBOT499`.

## Fixed-count semantics

`FIXED_COUNT_SEMANTICS=CONFIRMED`, with one locally verified implementation caveat.

1. `UseFixedClassRaceCounts` defaults to `false` (`PlayerbotAIConfig.cpp:406`).
2. The normal probability array is initialized first: race defaults use 100 when absent, class-only overrides use -1 as “not specified”, and exact class/race overrides also use -1 (`PlayerbotAIConfig.cpp:409-458`). Invalid factory combinations are forced to probability 0.
3. In fixed mode, race-only and class-only keys are explicitly unsupported and ignored (`PlayerbotAIConfig.cpp:462-479`).
4. An exact valid `AiPlayerbot.ClassRaceProb.<class>.<race>` value >= 0 is inserted unchanged into `fixedClassRaceCounts` (`PlayerbotAIConfig.cpp:482-497`). It is therefore an absolute requested count, not a weight.
5. A missing exact key is absent from the fixed map. Consumers using `fixedClassRaceCounts[{class,race}]` obtain 0 for that missing key (`RandomPlayerbotMgr.cpp:1183-1186`).
6. Invalid combinations do not need explicit zero entries. They are forced to probability 0 and are ignored by the fixed map. The proposal deliberately omits them. Explicit zero entries are also avoided because `RandomPlayerbotFactory` copies all fixed-map entries into `remaining` and decrements an entry only after creation; a zero-valued valid entry can underflow (`RandomPlayerbotFactory.cpp:879-953`).
7. The fixed creation request is the sum of the exact fixed-map values. The factory does not subtract already existing characters from those requested counts before creating; it only encounters per-account slot limits. Consequently, fixed counts are not a rebalance or migration mechanism for the existing 4500-character pool.
8. Online population remains independently controlled by the `bot_count` event derived from `MinRandomBots`/`MaxRandomBots` (`RandomPlayerbotMgr.cpp:671-676`). The current event value is 50. A proposed fixed total of 52 does not automatically change that online limit.

Implementation caveat: `PlayerbotLoginMgr::GetClassRaceBucketSize` returns the normal `classRaceProbability` array even in fixed mode (`PlayerbotLoginMgr.cpp:732-742`), instead of the fixed map. The current config has `AsyncBotLogin=0`, so this path is inactive now. A complete exact entry for every effective valid pair is nevertheless required so no inherited default remains if this path is later enabled.

There is no separate `AiPlayerbot.FixedClassRaceCounts` config namespace in the local source. `fixedClassRaceCounts` is the internal map populated from the exact `ClassRaceProb.<class>.<race>` keys.

## Local databases and validity sources

- Realm: 1
- Login DB: `tw_logon`
- World DB: `tw_world`
- Character DB: `tw_char`
- MariaDB endpoint: `127.0.0.1:3307`
- Character-creation table: `tw_world.playercreateinfo`

`ObjectMgr::LoadPlayerInfo` reads `race` and `class` from the World DB `playercreateinfo`, validates both against the local DBC stores and playable masks, validates the start position, then populates `m_PlayerInfo` (`ObjectMgr.cpp:2898-2963`).

Two separate local validity layers exist:

- `playercreateinfo`: 59 character-creation combinations.
- `RandomPlayerbotFactory` under the compiled `MANGOSBOT_ZERO` branch: 52 combinations.
- Effective randombot matrix (intersection): 52 combinations.

The seven DB-valid combinations absent from the randombot factory are:

- Orc / Mage (race 2, class 8)
- Dwarf / Mage (race 3, class 8)
- Dwarf / Warlock (race 3, class 9)
- Undead / Hunter (race 5, class 3)
- Tauren / Priest (race 6, class 5)
- Gnome / Hunter (race 7, class 3)
- Troll / Warlock (race 8, class 9)

They cannot be copied into a working fixed-count config without a source change, which was outside this task. `VALID_COMBINATION_COUNT` therefore denotes the 52 combinations effective for local randombot generation; the 59-row character-creation layer is reported separately.

## Locally verified races and classes

Local `ChrRaces.dbc` contains 10 races. Goblin is race ID 9 and High Elf is race ID 10. These values also match local `SharedDefines.h` and are not imported from another WoW version.

- Goblin (9): Warrior, Hunter, Rogue, Mage, Warlock.
- High Elf (10): Warrior, Paladin, Hunter, Rogue, Priest, Mage.

Local `ChrClasses.dbc` contains nine playable classes: Warrior 1, Paladin 2, Hunter 3, Rogue 4, Priest 5, Shaman 7, Mage 8, Warlock 9, Druid 11. Class 6 is not a playable class in this Zero build.

## Current random-bot inventory

The inventory query joined `tw_char.characters.account` to `tw_logon.account.id` and restricted accounts to the exact configured names `RNDBOT0` through `RNDBOT499`. There are exactly 500 such accounts, no additional prefix-matching accounts, and 4500 characters (nine per account).

- Effective combinations currently missing: 0 of 52.
- `playercreateinfo` combinations currently missing: the seven factory-unsupported pairs listed above.
- Equal-share reference for the current pool: `4500 / 52 = 86.538462`.
- Overrepresented relative to that reference: 18 combinations.
- Underrepresented relative to that reference: 34 combinations.
- Minimum: Troll / Priest = 8.
- Maximum: High Elf / Warrior = 196.

The `ai_playerbot_random_bots` table is event/state, not the character inventory. It currently contains 53 distinct `add` bots and one `bot_count=50` event; this is intentionally reported separately from the 4500 stored randombot characters.

## Proposals (not applied)

| Proposal | Fixed count per effective combination | Total | Exact requested target |
|---|---:|---:|---|
| A | 1 | 52 | one per combination |
| B | 2 | 104 | two per combination |
| C | 1 | 52 | closest strict equal positive distribution to 50; 50 is impossible |

Because 50 is not divisible by 52, strict equality at a total of exactly 50 is mathematically impossible. Proposal C recommends 1 per combination, total 52, a deviation of +2. With the current online target of 50, all 52 combinations cannot be online simultaneously.

The generated proposal is prospective only. The existing 500 accounts are already full, and the local fixed-count factory does not delete or rebalance existing characters. Applying the proposal as-is would therefore not normalize the current 4500-character inventory.

## Required result fields

```text
CLASS_RACE_MATRIX_RESULT=PASS
FIXED_COUNT_SEMANTICS=CONFIRMED
RACE_COUNT=10
CLASS_COUNT=9
VALID_COMBINATION_COUNT=52
CURRENT_RANDOMBOT_COUNT=4500
MINIMUM_BOTS_FOR_FULL_COVERAGE=52
EXACT_EQUAL_DISTRIBUTION_WITH_50=NO
RECOMMENDED_FIXED_COUNT_PER_COMBINATION=1
```
