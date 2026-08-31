# PLAYERBOT-DISCOVERY-AND-MATRIX-PREFLIGHT-02

Captured UTC: 2026-08-30T15:50:39.4340353Z

## Scope and decision

This package is read-only with respect to configuration, databases, source, and server processes. No database engine or game server was started. Only aggregated and sanitized evidence was created in this directory.

DISCOVERY_PREFLIGHT_RESULT=BLOCKED

The source/config, 59-versus-52 matrix, current stock, levels, professions, effective low-level runtime roles, and planning matrices are proven. The preflight remains BLOCKED only because the current persistent group membership and stored specNo events were not captured after the group-table files changed. Starting MariaDB was expressly outside this task. A Worldserver restart is not required; a separately authorized MariaDB-only read capture is sufficient.

## Status fields

`ini
DISCOVERY_PREFLIGHT_RESULT=BLOCKED
SOURCE_CONFIG_IDENTITY_VERIFIED=YES
PLAYERCREATEINFO_PAIR_COUNT=59
RNDBOT_OBSERVED_PAIR_COUNT=52
PLAYERBOT_GENERATABLE_PAIR_COUNT=52
PAIR_DIFFERENCE_RESOLVED=YES
CURRENT_RNDBOT_STOCK_COUNT=4500
CURRENT_ACTIVE_EVENT_GUID_COUNT=0
CURRENT_STORED_ADD_EVENT_ROW_COUNT=53
CURRENT_ONLINE_RNDBOT_COUNT=0
CURRENT_GROUP_LOGIN_CANDIDATE_COUNT=UNPROVEN
TIME_BASED_ROTATION_CONFIRMED=YES
LEVEL_CAP_REPLACEMENT_CONFIRMED=NO
RESTART_TEST_REQUIRED=NO
BOTS_WITH_ZERO_PRIMARY_PROFESSIONS=4491
BOTS_WITH_ONE_PRIMARY_PROFESSION=5
BOTS_WITH_TWO_PRIMARY_PROFESSIONS=4
BOTS_WITH_MORE_THAN_TWO_PRIMARY_PROFESSIONS=0
SPEC_MAPPING_CONFIDENCE=HIGH
STORED_SPECNO_DISTRIBUTION=UNPROVEN
WEIGHTED_MATRIX_50_READY=YES
WEIGHTED_MATRIX_100_READY=YES
WEIGHTED_MATRIX_500_READY=YES
WEIGHTED_MATRIX_1000_READY=YES
PRODUCTION_CONFIG_CREATED=NO
`

CURRENT_ACTIVE_EVENT_GUID_COUNT=0 is the effective timer-active count at package capture. The 53 physical owner=0,event=add rows are still stored, but every accepted 	ime + validIn deadline is in the past. GetBots() initially loads those rows; GetEventValue() evaluates them as zero, and the normal manager path then removes/logs out the expired rotation entries.

## Active configuration identity

- Path: $ConfigPath
- Bytes: 283717
- SHA-256: $(Get-Sha256 C:\TW\ComTW\server\aiplayerbot.conf)
- Resolution: mangosd.conf leaves AiPlayerbot.ConfigFile empty; PlayerbotAIConfig.cpp:100-128 resolves the bot config next to the active main config.

Effective control values:

| Setting | Effective value | Meaning |
|---|---:|---|
| AiPlayerbot.Enabled | 1 | Playerbot module enabled |
| RandomBotAutologin | 1 | Legacy random-bot manager enabled |
| RandomBotAutoCreate | 1 | Startup scans/creates random accounts and missing characters |
| MinRandomBots / MaxRandomBots | 50 / 50 | Global ot_count target |
| AsyncBotLogin | 0 | Legacy selector is active; PlayerbotLoginMgr is inactive |
| RandomBotTimedLogout | omitted, default 1 | Rotation timers are active |
| MinRandomBotInWorldTime / MaxRandomBotInWorldTime | omitted, defaults 1800 / 21600 seconds | Per-login rotation lifetime |
| RandomBotTimedOffline | omitted, default 0 | No enforced offline timer |
| DisableRandomLevels | 1 | Bots level naturally; normal random level reassignment is disabled |
| andombotStartingLevel | 1 | New bots start at level 1 |
| SyncLevelWithPlayers / MaxAbove / NoPlayer | 1 / 4 / 1 | Legacy candidate query prefers a level window, but its final fallback removes that filter |
| ClassRace.UseFixedClassRaceCounts | omitted, default 0 | Current distribution is probability-based |
| RandomBotLoginAtStartup | 1 | Loaded but no consumer exists in this source tree |
| LogInGroupOnly | omitted, default 1 | Misleading name: it gates Engine diagnostic logging, not bot login |

The complete relevant raw ranges and every matching setting line are in ctive-config-randombot-classrace-excerpt.txt and ctive-config-relevant-lines.csv.

## 59 schema pairs versus 52 factory pairs

The accepted live playercreateinfo evidence contains 59 unique pairs. Its physical MyISAM table files are older than that capture and remain unchanged. RandomPlayerbotFactory::availableRaces allows exactly 52 pairs. The 4,500 current RNDBOT rows contain exactly those same 52 pairs.

The seven schema-valid but factory-rejected pairs are:

| Race | Class | Active config line | Effective bot probability |
|---|---|---|---:|
| Orc | Mage | none | 0 |
| Dwarf | Mage | none | 0 |
| Dwarf | Warlock | none | 0 |
| Undead | Hunter | none | 0 |
| Tauren | Priest | none | 0 |
| Gnome | Hunter | none | 0 |
| Troll | Warlock | none | 0 |

They begin at the default probability 100, but PlayerbotAIConfig.cpp:446-456 calls isAvailableRace() and forces each rejected pair to zero. This resolves the discrepancy: 59 is the World schema matrix; 52 is the actual Playerbot factory/login matrix.

Among the 52 supported pairs, 40 have explicit pair overrides and 12 use the implicit default 100. The 12 defaults are Human Hunter plus the supported Goblin and High Elf combinations. The effective probability total is 2,483. At target 50, the legacy probability formula creates aggregate class/race allowances totaling 83, while the global target still stops selection at 50; it is a probabilistic cap, not an exact matrix.

## Fixed-count semantics

Fixed mode is understood but is not ready for a production config in this task:

1. Startup creation copies configured exact pair counts into emaining and creates new characters only in unused account slots. It does not subtract or rebalance the 4,500 existing characters and deletes none.
2. The current 500 accounts already contain 4,500 characters (nine each), so there are no creation slots.
3. The active legacy selector (AsyncBotLogin=0) uses ixedClassRaceCounts as per-pair selection quotas for existing bots.
4. The inactive async selector has a source inconsistency: PlayerbotLoginMgr::GetClassRaceBucketSize() returns classRaceProbability in fixed mode instead of ixedClassRaceCounts. Omitted supported pairs therefore behave as default 100 in that path.
5. Fixed parser entries with value zero are retained. The creation loop decrements the unsigned zero and can underflow if a free character slot exists. A 50-of-52 candidate must therefore not encode zero entries without a separate source review/fix.

No fixed-count switch or production config is generated. Model and target approval must come first, and the async/zero-count source defects require their own narrowly scoped change candidate if fixed mode is selected.

## Selection, rotation, level, and group behavior

- PlayerbotWorldScript::OnStartup() always calls CreateRandomBots() when the module is enabled.
- The legacy manager normalizes global ot_count into the configured 50..50 range and selects from RNDBOT accounts until that target is reached.
- Candidate account order is shuffled on each pass. Fixed counts control pair totals, not GUID identity.
- Successful login assigns a fresh dd timer. Expired dd causes controlled logout/removal, except grouped bots receive a 120-second deferral. The manager then fills the global target with other eligible bots. This confirms time-based rotation.
- No source path replaces a bot merely because it reaches RandomBotMaxLevel. With DisableRandomLevels=1, normal level/spec randomization returns early. Level sync affects preferred candidate queries, but the third legacy fallback removes the level predicate when needed.
- AddOfflineGroupBots() can add 1..5 offline group bots for an online real-player group leader outside the ordinary target-filling loop. The last accepted group query is stale because all four active group data/index files were written later. Current group-login candidates are therefore unproven, not assumed zero.
- No Worldserver is running, so the actual in-memory online RNDBOT GUID set is empty.

## Current population

- Stock: 4,500 RNDBOT characters, 52 observed pairs.
- Levels: 1=4,382; 2=10; 3=5; 4=7; 5=12; 6=53; 7=27; 8=2; 9=2.
- Stored add rows: 53; effective unexpired add timers at capture: 0; online in world: 0.
- The detailed aggregate is ndbot-population-race-class-level.csv. GUID-level deliverables are separated into stored-add, empty online, and explicitly superseded last-accepted group snapshots; none contains names or accounts.

## Professions

- Zero primary professions: 4,491.
- One primary profession: 5.
- Two primary professions: 4.
- More than two: 0.
- Learned primary skills: Blacksmithing 1, Leatherworking 1, Alchemy 2, Herbalism 5, Mining 3, Skinning 1.
- Learned secondary skills: First Aid 5, Cooking 3, Fishing 4, Survival 4.
- Survival (skill 142) is a locally verified secondary custom profession and does not count against the primary limit.
- Complete manufacturing/gathering pair: Alchemy + Herbalism, one bot.
- Orphan manufacturing professions: Alchemy without Herbalism 1; Blacksmithing without Mining 1; Leatherworking without Skinning 1. Engineering, Jewelcrafting, Enchanting, and Tailoring are not currently learned by any RNDBOT in this capture.

No profession is taught, removed, or recommended for direct SQL manipulation here.

## Talent/spec/role mapping

The character database persists learned talent spells in character_spell; there is no separate vanilla character_talent table. AiFactory::GetPlayerSpecTabs() walks Talent/TalentTab DBC rows and sums ranks for spells found by Player::HasSpell(). For level 10+ it chooses the highest-point tab. specNo is a persistent Playerbot event used to select a configured premade path, but current specNo rows were not captured in the accepted read-only evidence.

All 4,500 current RNDBOTs are level 1..9. AiFactory::GetPlayerSpecTab() therefore uses its deterministic low-level fallback rather than learned talent points. The effective current runtime mapping is high-confidence:

| Class | Fallback spec | Runtime role | Count |
|---|---|---|---:|
| Warrior | Protection | Tank | 719 |
| Paladin | Retribution | DPS | 424 |
| Hunter | Beast Mastery | DPS | 959 |
| Rogue | Assassination | DPS | 717 |
| Priest | Holy | Healer | 362 |
| Shaman | Enhancement | DPS | 155 |
| Mage | Fire | DPS | 574 |
| Warlock | Affliction | DPS | 393 |
| Druid | Balance | DPS | 197 |

Role totals are Tank 719, Healer 362, DPS 3,419. This is the effective low-level runtime role distribution, not proof of stored specNo choices or future level-10+ talent distributions.

## Matrix models

Every matrix uses the 52 factory-supported pairs and assigns target zero to the seven schema-only pairs. No deletion is proposed. Each matrix-N.csv contains both models and, per pair, current stock, stored/effective event counts, target, and dd_deficit = max(target - current_stock, 0).

Equal-pair comparison:

- split the target exactly 50/50 by faction;
- assign the same base count to every supported pair within a faction;
- assign indivisible remainders to the currently least represented target race, then class, then numeric pair ID.

Recommended class-rarity/race/faction-balanced model:

- split the target exactly 50/50 by faction;
- maximize distinct supported-pair coverage before assigning a second seat to any pair;
- repeatedly give the next seat to the faction-local class with the smallest target total;
- break ties by the race with the smallest target total, then pair count and numeric IDs.

This gives scarce classes more seats per valid pair while retaining faction balance and strong race balance. It is a planning matrix only. It does not select GUIDs, alter events, or create characters.

## Remaining proof gap and next gate

No controlled Worldserver restart test is required. Before a production config candidate, perform one separately authorized MariaDB-only read capture of:

1. current owner=0,event IN ('add','login','specNo') rows;
2. current RNDBOT group members and leader account type;
3. current characters.online flags as consistency evidence;
4. stored specNo distribution.

Then approve a target size and one matrix model. Any fixed-count source correction, GUID-cohort mechanism, profession pairing, spec behavior, grouping lifecycle, gear scoring, gathering, quest turn-in, or LLM context remains a separate candidate and rollback point.

## Git and process state

- Repository: $Repository
- Branch: $branch
- HEAD: $head
- Server process count at capture: 0
- Listener count on ports 3307/8090 at capture: 0

Git status at capture:

`	ext
 M src/modules/PlayerBots/CMakeLists.txt
 M src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.cpp
 M src/modules/PlayerBots/playerbot/PlayerbotLLMInterface.h
 M src/modules/PlayerBots/playerbot/strategy/actions/DebugAction.cpp
?? bin/Release/MoveMapGen.pdb
?? bin/Release/mangosd.pdb
?? bin/Release/mapextractor.pdb
?? bin/Release/realmd.pdb
?? bin/Release/vmap_assembler.pdb
?? bin/Release/vmapextractor.pdb
`

No config, database, source, server executable, or existing evidence file was modified.
