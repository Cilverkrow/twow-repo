# Race/class expansion for train 10: tauren paladin, night elf and high elf shaman (bots first)

Refs #379. Status: **design only**. This document changes no spell, DBC, SQL or
core code.

**Binding contract:** [#379](https://github.com/Cilverkrow/twow-repo/issues/379)
with the owner decision of 2026-10-04
([issuecomment-5978982721](https://github.com/Cilverkrow/twow-repo/issues/379#issuecomment-5978982721)),
the OB-40 analysis in [#518 issuecomment-5978827314](https://github.com/Cilverkrow/twow-repo/issues/518#issuecomment-5978827314)
and the rare-pair cap of [#521](https://github.com/Cilverkrow/twow-repo/pull/521).
In short:

- **New pairs:** tauren paladin (6/2), night elf shaman (4/7), high elf shaman
  (10/7, Turtle custom race 10).
- **Existing bot-only pairs:** dwarf shaman (3/7) and undead paladin (5/2),
  merged with [core#165](https://github.com/Cilverkrow/twow-core/pull/165),
  [core#178](https://github.com/Cilverkrow/twow-core/pull/178) and
  [core#179](https://github.com/Cilverkrow/twow-core/pull/179) on 2026-09-27.
  They lack the player client part and the class-quest rewards.
- **Bots first**, then the client for players **collectively in one patch**
  (called patch v9 here, after the owner's wording; OB-15 assigns the number, §5.4).
- **Class-quest rewards** for factions without the class quests (Horde paladin,
  Alliance shaman): as a trainer spell, or granted into the bag from a level.
  Owner proposal for totems: earth 5, fire 10, water 20, air 30 (to be confirmed).
- **Rare pairs stay rare:** cap of about 2.5 % of the faction per pair (#521).
  What the owner means by "Vorrang" for the more common Horde pairs is open (D12);
  the generator has no faction-specific rule (§4.4).
- Raids and bosses moved to train 11, so train 10 carries this work.

**Correction to the brief** (§1.3): dwarf warlock (3/9) is **not** bot-only. It
is a Turtle base pair and player-creatable today. Only 3/7 and 5/2 lack the
client part.

Related: #356 (ClassGrant), #357 (shaman tank, shaman swords), #367 (rogue tank),
#455 (client/server sync), #503 (one SRCI block per skill), #514 /
[core#294](https://github.com/Cilverkrow/twow-core/pull/294) (SLA class masks),
#488 / #512 (train-9 client content), #518 / #521 (roster plan, names, rare cap),
CLI-485 / core#281 (guild fill), #295 (riding).

Marks: **[V]** read in code or data in this session (file:line, table, id) ·
**[A]** assumption, community knowledge or not verified · **[D]** design
proposal that needs OB-20 / owner approval.

## 0. Evidence base

| Source | Version |
|---|---|
| twow-core | `origin/main` = `9a08bf2d`, read with `git show` / `git grep` only |
| twow-repo | `main` = `18d471e4` (worktree `cli379-docs`) |
| World data | disposable DB `cli484-db`, schema `tw_world_main` (world state of train 8b / main), SELECT only |
| Client base | Turtle 1.18.1 enUS DBCs, hashes equal to `ops/clientpatch/bases/turtle-1.18.1-enUS.toml:21,25,107,109` (CharBaseInfo, CharStartOutfit, SkillRaceClassInfo, SkillLineAbility) |
| Our patch 7 | `builds\ob15-clientpatch-v7\extract-a\DBFilesClient` |
| Glue | `Interface\GlueXML\CharacterCreate.lua/.xml` from Turtle's own `patch-9.mpq`, read in a throw-away container, nothing copied |

No live DB, live container or live config was read. Statements about the live
state come from issue texts or the canonical config and are marked [A]. Client data
is described only by ids, masks and our own words. Core paths are relative to
`twow-core`; bot paths relative to `modules/mod-playerbots/src/playerbot/`.

## 1. Current state of the existing pairs

### 1.1 What is on main

| Commit / PR | Content [V] |
|---|---|
| `878de754`, core#165 | world migration `sql/database_updates/20260927120000_world.sql` for (3,7) and (5,2); factory allow-list + `isClassForTeam()`; group fill asks the factory; 2 contracts |
| `892c0836`, core#178 | factory allow-list + 7 Turtle pairs (2/8, 3/8, 3/9, 5/3, 6/5, 7/3, 8/9); no SQL, the data existed |
| `b63bf43a`, core#179 | `Player.cpp:21889` `IsDwarfShamanHordeRacial()` lifts the SLA race mask for Hex 45504, Feral Spirit 45505/45514, Ethereal Form 45502 (used at `:21915`); contract `t/check_dwarf_shaman_racials_contract.cmake` |
| `f8a606df` | `sql/database_updates/world/20260517101017_world.sql`: Turtle start data of (3,9) and (6,5) |
| `0ee07489` | table `skill_race_class_info_mod` + loader `SpellMgr::LoadSkillRaceClassInfoMap` |

Migration `20260927120000_world.sql` [V]: `player_levelstats` 1..60 (l.28-149;
dwarf shaman = orc shaman + dwarf−orc rogue delta, undead paladin = human paladin +
undead−human rogue delta), `_spell` (152-232; 40 and 39 rows), `_action` (235-249),
`_item` (252-273, all `allowable_race = -1`), `playercreateinfo` last (276-282, only
if 60 levelstats rows exist), fail-closed CHECK tail (286-302). Not included by
brief: `skill_race_class_info_mod`, `skill_line_ability`, trainers, class-quest
grants, client.

### 1.2 Data check in `tw_world_main` [V]

| Pair | pci | levelstats | spells | actions | items | client CharBaseInfo |
|---|---|---|---|---|---|---|
| 3/7 dwarf shaman | 1 (Coldridge) | 60 | 40 | 7 | 6 | **missing** |
| 5/2 undead paladin | 1 (Deathknell) | 60 | 39 | 6 | 7 | **missing** |
| 3/9 dwarf warlock | 1 | 60 | 35 | 7 | 8 | present (CSO 39/40) |
| 2/8, 3/8, 5/3, 6/5, 7/3, 8/9 (core#178) | 1 each | 60 each | 33-38 | 5-6 | 7-10 | present |
| 6/2, 4/7, 10/7 (train 10) | 0 | 0 | 0 | 0 | 0 | missing |

Base CharBaseInfo has 59 rows; the only server pairs the client does not know are
**(3,7) and (5,2)** (server: 61 pairs); the client knows no pair the server lacks.

### 1.3 Gaps of the existing pairs

| Item | 3/7 dwarf shaman | 3/9 dwarf warlock | 5/2 undead paladin |
|---|---|---|---|
| Server start data, levelstats, factory, contracts | done [V] | done [V] | done [V] |
| SRCI / `skill_race_class_info_mod` | not needed [V] | not needed [V] | not needed [V] |
| Server SLA | racials via code bypass (core#179) | ok | ok |
| Client CharBaseInfo + CharStartOutfit | **missing** | present | **missing** |
| Client SLA race mask of Hex/Feral Spirit/Ethereal Form | **excludes dwarf**; display effect [A] | – | – |
| Player trainer in own faction | **missing** | present | **missing** |
| Class-quest rewards, bots | totems + rank-1 spells via ClassGrant [V code; live switch A] | via quests (589 includes dwarf) [V] | **missing**: Redemption chain, Sense Undead, Warhorse, Charger [V] |
| Class-quest rewards, players | **missing** | ok | **missing** |
| Racials of core#179 actually learnable | **only Feral Spirit r2 at L60** (§3.4) [V] | – | – |
| Live bots of the pair | none [A, #518 text] | none [A] | none [A] |

The dwarf warlock needs nothing: Alliance warlock quests carry race mask 589
(includes dwarf), the L30+ quests mask 0 [V `quest_template`].

### 1.4 Lessons that bind train 10

1. **Client SLA masks decide the display.** Shamans with Ancestral Arms showed
   "Melee Attack 0" because SLA 5/7 (swords) lacked the shaman class bit
   (core#294, #514, both open). Any race or class exception has to change server
   `skill_line_ability` **and** client SkillLineAbility in parity (rule
   `skill-line-ability-matches-server`, `ops/clientpatch/consistency/server.toml:519-545`).
2. **One SRCI block per skill in the client (#503).** Appended SRCI rows split a
   skill's block and the client lost swords. The pipeline now places new rows
   behind their block. Train 10 needs **no** SRCI row (§2.4).
3. **`skill_race_class_info_mod` semantics** (`SpellMgr.cpp:2671-2772`) [V]: an
   existing DBC id is replaced in place (`-1` = keep); an unknown id is appended and
   needs every field; `SkillCostIndex` must be `-1`. The server takes the first
   matching row (`:2774-2788`); the client depends on order.
4. **`player_levelstats` 1..60 is mandatory.** `ObjectMgr::LoadPlayerInfo` calls
   `exit(1)` when a loaded pair has no level-1 stats (`ObjectMgr.cpp:3483-3488`)
   [V]. Hence: levelstats first, `playercreateinfo` last, CHECK tail.
5. **Contracts pin exact rows and file names.** `t/check_race_class_379_contract.cmake`
   forbids other tuples in the core#165 file (l.57); the availability contract
   (`t/race_class_availability_source_contract_tests.cmake`, registered
   `modules/mod-playerbots/tests.cmake:1286`) pins the allow-list (l.80-101) and a
   hard-coded list of migration files (l.115, l.121). Train 10 needs a **new**
   migration file and an extended availability contract.
6. **Bots skip race-locked class quests** (`SatisfyQuestRace`,
   `AutoLearnSpellAction.cpp:257-260`) [V]. Only the shaman has a ClassGrant
   table today; Horde paladins get nothing.

## 2. Requirement tables for the new pairs

Template rule as in core#165 [V]: start from a pair of the same class, swap the
race parts (start position, languages, racials, food) from existing rows of the
race, derive `player_levelstats` with a race offset constant over all 60 levels.

### 2.1 Tauren paladin (6/2)

| # | Item | Content | Status |
|---|---|---|---|
| S1 | `player_levelstats` 1-60 | human paladin (1,2) + tauren−human **priest** offset (+5 str, −5 agi, +2 sta, −5 int, +2 spi), the only offset constant on 60/60 levels. L1 27/15/24/15/23, L20 47/26/43/27/36, L40 75/41/69/44/56, L60 110/60/102/65/77 | [V] offsets, [D] method |
| S2 | `playercreateinfo` | map 1, zone 215 Camp Narache (-2917.58, -257.98, 52.9968, 0) | [V] |
| S3 | `playercreateinfo_spell` | 39 rows: (1,2) set minus 668 Common, 20597, 20598, 20599, 20600, 20864 (human racials) plus 669 Orcish, 670 Taurahe, 20549 War Stomp, 20550 Endurance, 20551 Nature Resistance, 20552 Cultivation | [V] |
| S4 | `playercreateinfo_action` | 0 6603 Attack, 1 21084 Seal of Righteousness, 2 635 Holy Light, 3 20549 War Stomp, 10 item 159, 11 food | [V] templates, slot 3 [D] |
| S5 | `playercreateinfo_item` | 43, 44, 45 (Squire's set), 2361 Battleworn Hammer, 159 ×2, food ×4, 6948 Hearthstone; all `allowable_race = -1` | [V]; food [D] §2.5 |
| S6 | Racials | War Stomp, Endurance, Nature Resistance, Cultivation; SLA 4113-4116 skill 124, race 0x20, class 0 | [V] |
| S7 | Languages | Orcish (SRCI 48, race 434, class mask 0x5DF incl. paladin), Taurahe (SRCI 50, race 0x20) | [V] |
| S8 | `skill_race_class_info_mod` | **none** | [V] §2.4 |
| S9 | Class, weapon, armour skills | Holy 594, Protection 267, Retribution 184, Shield 433, Mail 413 (SRCI 146, class 3, from L1), Plate 293 (SRCI 21, MinLevel 40); maces/swords/axes/polearms SRCI race 0x7FF, SLA race 0. 1.12 has no libram skill | [V] |
| S10 | Talents | TalentTab 381/382/383 RaceMask 0x3FF, ClassMask 0x2 | [V] |
| S11 | Trainer spells, bots | nothing: `AutoLearnTrainerSpells` scans every class trainer without faction filter (`AutoLearnSpellAction.cpp:32-76`, fix-point `:124-138`; on create `PlayerbotFactory.cpp:296`) | [V] |
| S12 | Quest-only rewards | Redemption r1, Sense Undead, Warhorse, Charger missing (§3.1) | [V] gap |
| S13 | Trainer access, players | no Horde-friendly paladin trainer (§3.5) | [V] gap |
| S14 | Factory allow-list | `availableRaces[CLASS_PALADIN].push_back(RACE_TAUREN)` next to `RACE_UNDEAD` (`RandomPlayerbotFactory.cpp:53-59`), outside `#ifndef MANGOSBOT_ZERO` | [V] place |
| S15 | Mounts, bots | `InitMounts` (`PlayerbotFactory.cpp:4492`, race switch `:4548ff`) gives tauren kodos by race | [V] |
| C1 | CharBaseInfo | + `6:2`; tauren goes to 6 classes | [V] |
| C2 | CharStartOutfit | + 2 rows (m/f), copy of human paladin rows 3/4, RaceID 6, food swapped; **feet slot (43 Squire's Boots, InventoryType 8) cleared** (ItemID −1, Display −1, InvType −1), because no Turtle tauren CSO row (63-72) has a feet slot | [V] data, [D] |
| C3 | SRCI / SLA / TalentTab / ChrRaces / ChrClasses | none | [V] |
| C4 | Glue | none (class buttons from `GetClassesForRace()`, 8 buttons) | [V] lua, [A] engine |
| C5 | Model / animation / voice | tauren warriors already use shield, 1H/2H maces, plate and mail; spell visuals are race-independent; check Holy Light / seal cast animations on tauren m/f in the probe | [A] |
| C6 | Mount look | Warhorse 13819 → creature 9158, Charger 23214 → 14565 (horse models); ChrRaces MountScale tauren 0.75. No paladin kodo in Spell.dbc | [V], look [A] |
| C7 | Boots on the server | item 43 has no race restriction; keep it in `playercreateinfo_item` for the stats. Client preview (C2) and server outfit then differ on purpose; ChrRaces tauren flag bit 0x2 "no feet" [A] | [V] data, [D] |

Strongest and most stamina-heavy paladin (L60 human 105/65/100/70/75, undead
104/63/101/68/80) plus Endurance: fits the tank role. All 60 rows:
`r2-tools\tauren-paladin-levelstats-derived.tsv` (appendix).

### 2.2 Night elf shaman (4/7)

| # | Item | Content | Status |
|---|---|---|---|
| S1 | `player_levelstats` 1-60 | orc shaman (2,7) + NE−orc offset (−6, +8, −3, +3, −3), constant on 60/60 levels for 4/1, 4/3, 4/4. L1 18/25/20/21/22, L20 34/34/38/38/41, L40 55/45/62/61/67, L60 82/60/94/90/100 | [V] |
| S2 | `playercreateinfo` | map 1, zone 141 Teldrassil (10311.3, 831.463, 1326.41, 5.48033) | [V] |
| S3 | `playercreateinfo_spell` | 41 rows: (2,7) set (39) minus 669, 20572, 20573, 20574, 21563 (orc) plus 668 Common, 671 Darnassian, 20580 Shadowmeld, 20582 Quickness, 20583 Nature Resistance, 20585 Wisp Spirit, 21009 Shadowmeld passive | [V] |
| S4 | `playercreateinfo_action` | 0 6603, 1 403 Lightning Bolt, 2 331 Healing Wave, 3 20580 Shadowmeld, 10 item 159, 11 item 4536 | [V] templates |
| S5 | `playercreateinfo_item` | 36 Worn Mace, 153 Primitive Kilt, 154 Primitive Mantle, 159 ×2, 4536 Shiny Red Apple ×4, 6948; no totem at start | [V], food [D] |
| S6 | Racials | NE racials SLA 4131-4134, 4258 (skill 126, race 0x8, class 0) | [V] |
| S7 | `skill_race_class_info_mod` | **none**; shaman swords 90043/90055 (#357) carry race 0x7FF | [V] |
| S8 | Class, weapon, armour skills | Enhancement 373, Restoration 374, Elemental 375 (SRCI 95/98/96 race 0x7FF); Mail SRCI 145 MinLevel 40; Shield 433; Totem relic 27763 (SLA 4899); Turtle shaman spells SLA race 0 | [V] |
| S9 | Race-masked shaman spells | client SLA: Hex 5075 (troll), Feral Spirit 5076/5077 (orc), Ethereal Form 6187 (tauren). Totemic Slam 45500 (SLA 6421) has race mask 0 | [V]; grant per D7 |
| S10 | Totems | ClassGrant gives bots items + rank-1 spells race-independently (§3.2) | [V] |
| S11 | Trainer access, players | no Alliance-friendly shaman trainer (§3.5) | [V] gap |
| S12 | Factory allow-list | `availableRaces[CLASS_SHAMAN].push_back(RACE_NIGHTELF)` (`RandomPlayerbotFactory.cpp:117-121`) | [V] place |
| C1 | CharBaseInfo | + `4:7`; NE goes to 6 classes | [V] |
| C2 | CharStartOutfit | + 2 rows, copy of orc shaman rows 21/22, RaceID 4, food slot → 4536 (display 6410 from `item_template`, equal to the NE druid row) | [V] data, [D] |
| C3 | SRCI / TalentTab / ChrRaces / ChrClasses / glue | none | [V] |
| C4 | SLA | none, unless D7 grants Horde racials (then widen 5075-5077/6187) | [V], [D] |
| C5 | Models | totem creatures have one race-neutral display each (Searing 4589, Healing Stream 4587, Stoneskin/Stoneclaw/Tremor 4588, Windfury 4590); Ghost Wolf default display 4613 (`Player.cpp:19976-19998`); NE warriors/hunters already show shields, maces, mail | [V] displays, [A] animations |

### 2.3 High elf shaman (10/7)

| # | Item | Content | Status |
|---|---|---|---|
| S1 | `player_levelstats` 1-60 | **D8.** Turtle splits high elves: 10/1, 10/3, 10/4 copy **orc** stats; 10/2, 10/5, 10/8 copy **human** stats plus an irregular spirit bonus (10/2: +1 at L1-20, 0 at L30-40, +3 at L50-60; 10/5: up to +6 at L60; 10/8: +2 at L20 only). Option A: orc shaman + human offset (−3, +3, −2, +3, −3) → L1 21/20/21/21/22, L60 85/55/95/90/100. Option B: identical to orc shaman. Option C: A plus the 10/2 spirit delta | [V] data, [D] |
| S2 | `playercreateinfo` | map 0, zone 5225 Thalassian Highlands (3212.63, -2501.44, 111.71, 0.79) | [V] |
| S3 | `playercreateinfo_spell` | 40 rows: (2,7) set minus the 5 orc spells plus 668 Common, 813 Thalassian, 26290 Bow Specialization, 46021 Quel'dorei Meditation (mana variant, as on 10/2/3/5/8), 46022 Enchanting Specialization, 52523 Swiftness of the Rangers. 52524 is left out on purpose: it exists only on 10/1 (warrior variant) | [V] |
| S4 | `playercreateinfo_action` | 0 6603, 1 403, 2 331, 3 46021, 10 item 80250, 11 item 80251. No high elf row has 46021 on the bar (10/2/10/5 have no racial button; 10/1/3/4 have Blood Fury 20572; 10/8 has 20577 on slot 3), so slot 3 is our choice; never copy those foreign racial buttons | slots 0-2, 10-11 [V]; slot 3 [D] |
| S5 | `playercreateinfo_item` | 36, 153, 154, 80250 Sun-Parched Waterskin ×2, 80251 Crusty Flatbread ×4, 6948; alternative Initiate set 24143/24145/24146 like 10/1, 10/2 (D10) | [V], [D] |
| S6 | Racials | high elf racials have **no** SLA rows; they come only from `playercreateinfo_spell` | [V] |
| S7 | `skill_race_class_info_mod` | **none** (as 4/7) | [V] |
| S8 | Class skills, race-masked spells, totems | as 4/7 (S8-S10) | [V] |
| S9 | Factory allow-list | `availableRaces[CLASS_SHAMAN].push_back(RACE_HIGH_ELF)`; high elf bots are relocated to Northshire with that homebind (`RandomPlayerbotFactory.cpp:586-592`) | [V] |
| S10 | **Pre-existing bug** | `IsAlliance(uint8)` (`PlayerbotAI.cpp:6561-6567`) lists human, dwarf, night elf, gnome but **not high elf**. Callers: `IsOpposing()` (`:7066-7068`) → `PlayerbotSecurity.cpp:46/165` refuses commands from ungrouped Alliance players; `AhBot.cpp:1173` wrong AH; `RandomPlayerbotMgr.cpp:4823`, `SayAction.cpp:36` wrong faction; `RandomPlayerbotMgr.cpp:2799` log letter only. Affects every high elf bot. **Fix: hotfix 8.21 (OB-20)** | [V] code, impact [A] |
| C1 | CharBaseInfo | + `10:7`; high elf goes to 7 classes | [V] |
| C2 | CharStartOutfit | + 2 rows, copy of orc shaman rows 21/22, RaceID 10; swap both food slots: 117 → **80251** (display 1483), 159 → **80250** (display 29439), display ids from `item_template.display_id` | [V] |
| C3 | Everything else | as 4/7; model prefix `BloodElf` (Turtle custom model); HE warriors/paladins/hunters already show shields, maces, mail | [V] / [A] |

### 2.4 Skill masks: why no SRCI or `skill_race_class_info_mod` row is needed [V]

Checked on base, patch 7 and server data (`r6srci.py`: first matching SRCI row per
skill, the rule of `SpellMgr::GetSkillRaceClassInfo`, against three reference
pairs per class):

| Target pairs | Weapon/class/armour skills of the references | Missing for the target |
|---|---|---|
| 3/7, 4/7, 10/7 | 20 (base) / 22 (p7, + swords 90043/90055) | 0 |
| 5/2, 6/2 | 21 | 0 |
| 3/9 | 14 | 0 |

The only differences are race-bound skills (racial lines, languages, race riding).
SkillLineAbility: all paladin, shaman, mail, shield, plate and totem rows have race
mask 0, except the four Horde shaman racials 5075/5076/5077/6187 (Totemic Slam 6421
is race 0). TalentTab: all 27 trees race 0x3FF. This also closes the core#165 open
point "check the DBCs before merge".

### 2.5 Start food and outfit [V data, D proposal]

Tauren start food is not uniform: 4540 on 6/1 and 6/5, 4604 on 6/7, 4536 on 6/11,
117 on 6/3. **Proposal:** 4540 for 6/2. Night elf: 4536 (druid) or 117
(warrior/hunter); proposal 4536. High elf: 80250/80251 as all 10/x server rows.

**Our convention, preview only:** server `playercreateinfo_item` and client
CharStartOutfit name the same food items. Turtle's own data does not follow this:
the high elf CSO rows carry 20857 (not in our `item_template`) and 159, the server
80250/80251; CSO shows item 43 with display 9938, `item_template` has 10272; items
24143/24145 show 36792/36791 vs 36789/36790 [V]. Rule: copied template display ids
stay as they are in the client; only swapped items take `item_template.display_id`.
For the existing pairs the client rows follow the server: 3/7 uses 4540 (orc
template had 117), 5/2 uses 4604 (human template had 2070).

## 3. Class-quest rewards

### 3.1 Paladin (Alliance-only today: `RequiredRaces = 589`) [V `quest_template`]

| Quest (final) | Min level | Reward | On a trainer? | Proposal |
|---|---|---|---|---|
| 1785 / 1788 The Tome of Divinity (chains 1641/1645/2997-3000) | 12 | cast 7329 → **Redemption r1 7328** | no. Ranks r2-r5 (10322/10324/20772/20773) are on 10 trainers each, but `spell_chain` 10322.prev = 7328 and `GetTrainerSpellState` returns RED without the previous rank (`Player.cpp:5419-5423`): **the whole chain is blocked** | grant at **12** |
| 1652 The Tome of Valor | 20 (quest level 25) | cast 5503 → **Sense Undead 5502** + item 9607 Bastion of Stormwind | no | spell at **20**; item: D6 |
| 1806 The Test of Righteousness | 20 (22) | item 6953 Verigan's Fist (2H mace) | – | D6 |
| 1661 The Tome of Nobility | 40 | cast 13820 → **Summon Warhorse 13819 + Apprentice Riding 33388** | no | **40**, riding per D5 |
| 8418 (8415 chain) | 50 (52) | 20620 + choice 20504/20505/20512 | – | D6 |
| 7647 Judgment and Redemption | 60 | cast 23215 → **Summon Charger 23214 + Journeyman Riding 33391** | no | **60**, riding per D5 |

**The mount teach spells also teach riding [V]:** `spell_template` 13820 has
effects (36, 36, 44) → 13819 and **33388 Apprentice Riding**; 23215 → 23214 and
**33391 Journeyman Riding**. The bot path `LearnSpellFromSpell`
(`AutoLearnSpellAction.cpp:487-510`) learns every LEARN_SPELL effect. Independently,
`Player::UpdateOldRidingSkillToNew` (called at every login, `Player.cpp:17398`;
body `:17443-17513`) teaches 33388 to any character without riding skill that knows
13819, and 33391 if it knows 23214. So **granting 13819/23214 directly does not avoid
free riding**; only a code change there would. Price before train 9: `npc_trainer_template`
1 sells 33389 for 900000 copper (90 g) at L40 and 33392 for 9000000 copper (900 g)
at L60 [V main]. **After #295 (train 9, core#275) riding 75 costs 50 silver and 150
costs 5 gold** (OB-20 review 5979966747), so the free part is small. Warlocks already
get the same today: `UpdateOldRidingSkillToNew` also teaches 33388 for Felsteed 5784
and 33391 for Dreadsteed 23161. Class mounts are spells, not items, so the #295 item
criterion (`required_skill_rank 225`) does not apply: the Charger rides at +100 % with
33391 as for Alliance paladins; +140/+180 % only with bought 225/300 as for everyone.
Alliance paladins get the same through their quests, so the grant is parity → D5b.

Intermediate quest items in the chains (bonding 4, used inside the chain, not gear):
1442 → 7083 Purified Kor Gem, 1655 → 6993 Jordan's Refined Ore Shipment (Verigan's
Fist chain), 7666 → 18746 Divination Scryer (after the Charger) [V]. They need no
grant.

**Endgame gaps, paladin (Horde paladins cannot take these)** [V `quest_template`,
all `RequiredClasses = 2`, `RequiredRaces = 589`]:

| Content | Quests | Reward |
|---|---|---|
| Dungeon Set 2 (T0.5) upgrade | 8908 An Earnest Proposition, 8954 Anthion's Parting Words, 9002 Saving the Best for Last (L58) | 22088; 22087 + 22092; 22091 + 22089 |
| AQ20 Eternal Justice | 8695 cape, 8703 ring, 8711 blade | 21397 / 21396 / 21395 |
| AQ40 Avenger's set | 8627, 8628, 8629, 8630, 8655 | choice 21389/21387/21390/21391/21388 (+ Turtle variants 4703x/4704x) |
| PvP | Insignia 18864 (race 589) is the only insignia with the paladin class bit | – |

Open to Horde paladins already (`RequiredRaces = 0`): T3 9043-9050, Turtle sets
41484-41500, Lionheart 41626-41631, ZG 8045-8055 [V].

### 3.2 Shaman (Horde-only today: `RequiredRaces = 434`) [V]

| Quest (final) | Min level | Reward | First trainer totem that needs the item | Proposal |
|---|---|---|---|---|
| 1518 / 1521 Call of Earth | 4 | item 5175 Earth Totem + cast 8073 → **Stoneskin r1 8071** | Earthbind 2484, L6 | **4** (bots today, Horde quest) or 5 (owner) |
| 1527 Call of Fire | 10 | 5176 Fire Totem + cast 2075 → **Searing r1 3599** | Fire Nova, L12 | 10 |
| 96 Call of Water | 20 | 5177 Water Totem + cast 5396 → **Healing Stream r1 5394** | Poison Cleansing, L22 | 20 |
| 1531 / 1532 Call of Air | 30 | 5178 Air Totem; 8385 Swift Wind is a one-off buff | Grounding / Nature Res, L30 | 30 |
| 41939 Vortalus' Edict (Turtle) | 20 | choice 58127/58128/58129 | – | D6 |
| 8413 Da Voodoo | 50 | choice 20369/20503/20556 | – | D6 |

Totem items 5175-5178: reagent, **BoP (bonding 1)**, `allowable_race = -1`, no
vendor, can be destroyed. `spell_template.totem1` binds 19/34/17/15 shaman spells
(spellFamilyName 11) to earth/fire/water/air, so **a shaman without the item cannot
cast any totem of that element** [V]. Rank 1 of Stoneskin, Searing and Healing Stream
is quest-only; ranks 2+ are on the Horde trainers and need rank 1 [V].

The owner's 5/10/20/30 is compatible with the data (Earthbind at 6 still finds the
earth totem). Earth 5 differs from the bot table and the Horde quest (both 4).
**Recommendation: earth 4**, one table for players and bots. If the owner keeps 5,
`ClassGrantPolicy.h:25` and `t/class_grant_policy_tests.cpp:24` change with it.

**Endgame gaps, shaman (Alliance shamans cannot take these)** [V, all
`RequiredClasses = 64`, `RequiredRaces = 434`]:

| Content | Quests | Reward |
|---|---|---|
| Darkreaver / Scholomance chain | 7667 → 8258, 7668 The Darkreaver Menace (L58); 41715 Again Into the Great Ossuary (L60, after 8258) | 20134 + 18807; 18807; 18746 |
| Dungeon Set 2 (T0.5) upgrade | 8918, 8957, 9011 (L58) | 22095; 22096 + 22100; 22097 + 22102 |
| AQ20 Gathering Storm | 8690 cloak, 8698 ring, 8706 hammer | 21400 / 21399 / 21398 |
| AQ40 Stormcaller set | 8602, 8621, 8622, 8623, 8624 | choice 21376/21373/21374/21372/21375 (+ Turtle variants 4715x/4716x) |
| PvP / Turtle | no Alliance insignia with class bit 0x40; 51831 Glyph of the Spectral Wolf race 162 | – |

### 3.3 Warlock

Nothing to do: Alliance warlock quests (1598/1599, 1689, 1739) use 589 incl.
dwarf, 1795 and the L30+ quests (4490, 7603, 7583, 7631) use 0 [V].

### 3.4 Turtle shaman racials (affects 3/7 today and every Horde shaman)

Turtle has three race-locked L40 chains [V `quest_template`, scripts]:

| Race | Final quest | How the racial is learned | Result |
|---|---|---|---|
| Orc | 40534 (race 2) | `RewSpellCast` 45519 = LEARN_SPELL → **Feral Spirit r1 45505** | works (players and bots) |
| Troll | 40353 (race 128) | script `QuestRewarded_npc_nribbi` calls `LearnSpell(45504)` (`src/scripts/miscellaneous/random_scripts_3.cpp:2390-2397`); `RewSpellCast` 45504 is the Hex aura itself (effects 6/6/6), not a teach spell | players: works by script; **bots: never** (bot quest path only learns LEARN_SPELL effects, `AutoLearnSpellAction.cpp:263-266`, `:487-510`) |
| Tauren | 40348 (race 32) | `RewSpellCast` 45500 Totemic Slam is a damage spell (effects 2/64), teaches nothing; script `QuestRewarded_npc_ancestor_of_wisdom` calls `LearnSpell(47262)` (`random_scripts_3.cpp:2274-2286`) | **47262 exists neither in `spell_template` nor in base Spell.dbc** → no working learn path for tauren either. **Fix 47262 → 47341 (LEARN_SPELL → 45502): hotfix 8.21 (OB-20)** [V data; live effect A] |

Further facts [V]: teach spell 47341 → Ethereal Form 45502 and 47263 → Hex 45504
exist but are on no trainer and no quest; the only trainer row is 45520 Feral Spirit
r2 at L60 on 12 trainers (no `spell_chain` row, no r1 needed).
`GetShamanSpellForRace` (`Player.cpp:10176-10183`) maps **tauren → 45500 Totemic
Slam**, troll → 45504, orc → 45505, other races → 0; it drives the race change
(`:10272`, `:23880`). Totemic Slam has client SLA 6421 with race mask 0; Ethereal
Form has SLA 6187 race 0x20. Which spell is "the tauren racial" is therefore
ambiguous (45500 in core, 45502 in client SLA and in core#179).

**Consequences:**
- The owner decision of 2026-09-27 for dwarf shamans is only partly delivered:
  they get Feral Spirit r2 at L60, never Hex, Ethereal Form or Feral Spirit r1.
- **Teach spell 47341 is the only path to Ethereal Form that works for every race.**
- Horde troll and tauren bots never get their own racial; tauren players probably
  neither (script bug, to confirm on the test realm).
- Fix in Phase B5 (D7): racial grant table (§3.6) and, separately, a fix of the
  tauren script (OB-10/OB-20; it touches every tauren shaman, not only #379).

### 3.5 Trainers [V `creature_template`, `npc_trainer`, `conditions`]

| Class | Entries | Factions | Gossip menu |
|---|---|---|---|
| Paladin (13) | 925, 926, 927, 928, 1232, 5147, 5148, 5149, 5491, 5492, 8140, 80220, 80244 | 12 Stormwind, 55 Ironforge, 894 Theramore, 371 Silvermoon Remnant: all Alliance | 4471, 4663, 4678, 2304, 56543, 59006 |
| Shaman (14) | 986, 3030, 3031, 3032, 3062, 3066, 3157, 3173, 3344, 3403, 13417, 62801, 62803, 62805 | 29 Orgrimmar, 104 Thunder Bluff, 1698 (Turtle, Horde [A]); 3062/3157 are 5-row start-area trainers | 4652, 4515, 62801-62805 |

`trainer_race = 0`, `trainer_id = 0` everywhere; `Creature::IsTrainerOf` checks only
`trainer_class` (`Creature.cpp:1260-1317`). Gossip conditions are class-only:
condition 92 = race/class type 14 with class mask 64, 106 = class mask 2; the
options use 134 (= 106 and level condition 107) and 137 (= 92 and 107). The text
variants of 4663 (conditions 454-461) were not resolved [A]. Bots need no trainer
(S11).

**Players [D]: new trainers need new `creature_template` entries**, not only spawns:

| Table | Content |
|---|---|
| `creature_template` | new entries (free id range from OB-40): off-faction `faction` (paladin: a Horde template per city, e.g. 104 as the Thunder Bluff shaman trainers, an Undercity template [A]; shaman: 12 / 55 / 371 as the Alliance paladin trainers), name, subname, `display_id1`, `npc_flags` gossip + trainer, `gossip_menu_id` 4471/4663 (paladin) or 4652 (shaman), `trainer_type` 0, `trainer_class` 2/7, `trainer_id` 0 or an `npc_trainer_template` id |
| `npc_trainer` or `npc_trainer_template` | copy of the 159 rows of 928 (paladin) / the 176 rows of 3344 (shaman) [V counts]; one shared template (via `trainer_id`, `ObjectMgr.cpp:8385`) keeps later rank changes in one place |
| `creature` | spawn rows: Thunder Bluff (+ near Camp Narache) and Undercity (+ Deathknell) for paladins; Ironforge (+ Coldridge), Darnassus (+ Teldrassil), Alah'Thalas / Thalassian Highlands for shamans |
| optional | `creature_equip_template`, `creature_addon`, gossip text of our own |

Everything is world SQL with migrations, so it ships only with a main train
(Ä15). Placement and names are an OB-20 rule question (D11).

### 3.6 Proposed grant design (Phase B input, not implemented)

**Two tables for players and bots.** Generalise `ClassGrantPolicy.h` (today
`ShamanTotems()`, l.21-31):

**Table A, class grants** `{class, level, item, teachSpell, canonicalQuest}`, gate
per row `!SatisfyQuestRace(canonicalQuest)` (all canonical quests carry 589 or 434,
so the gate is uniform):

| Class | Level | Item | Teach → learned | Canonical quest |
|---|---|---|---|---|
| Shaman | 4 (D2) | 5175 | 8073 → 8071 | 1518/1521 |
| Shaman | 10 | 5176 | 2075 → 3599 | 1527 |
| Shaman | 20 | 5177 | 5396 → 5394 | 96 |
| Shaman | 30 | 5178 | – | 1531/1532 |
| Paladin | 12 | – | 7329 → 7328 | 1785/1788 |
| Paladin | 20 | – | 5503 → 5502 | 1652 |
| Paladin | 40 | – | 13820 → 13819 **+ 33388 riding** (D5) | 1661 |
| Paladin | 60 | – | 23215 → 23214 **+ 33391 riding** (D5) | 7647 |

**Table B, racial grants** `{raceMask, class, level, teachSpell}`, **no quest
gate**, the race mask is the decision of D7 (example for "dwarf only"):

| Race mask | Class | Level | Teach → learned |
|---|---|---|---|
| dwarf (0x4) | Shaman | 40 | 47263 → Hex 45504 |
| dwarf (0x4) | Shaman | 40 | 47341 → Ethereal Form 45502 |
| dwarf (0x4) | Shaman | 40 | 45519 → Feral Spirit 45505 |

A per-row quest gate would be wrong here: a troll fails 40534 and 40348 and would
get Feral Spirit and Ethereal Form. If D7 also covers Horde bots (troll Hex, tauren
racial), they get rows with their own race bit.

**Scope gate [D]:** Table A only for characters that cannot take the canonical
quest. Alliance paladins and Horde shamans keep their quests (ADR-0031 organic
play). Alternative (owner, #379 point 3): all races of the class (D3).

**Items: re-grant when missing (D13).** At level-up and login: give the totem if
`!HasItemCount(item, 1, true)` (bags and bank). This is what bots already do
(`GrantShamanTotems`, `AutoLearnSpellAction.cpp:309-330`; `InitReagents` totem loop
`PlayerbotFactory.cpp:4829-4844`). Without it, an off-faction shaman who destroys a
BoP totem loses every totem spell of that element for good, because the quests stay
race-locked for him. Full bag: **no mail**; skip, log
`[ClassGrant] state=deferred reason=bag_full …` and retry at the next login or
level-up. Then no quest marker and no new table is needed (spells are idempotent by
`HasSpell`, items by `HasItemCount`). Do **not** reuse the mail branch of
`GetClassQuestItem` (`AutoLearnSpellAction.cpp:442-449`): it is unreachable because
the outer `if` already requires `EQUIP_ERR_OK` [V].

**Bots:** add the paladin rows and Table B next to the totem call at
`AutoLearnSpellAction.cpp:115-116` (`IsClassGrantBot()`: `ClassGrant.Enabled` +
persistent roster, `:304-307`). The grant runs **before** the trainer fix-point
(`:124`), so Redemption r1 unblocks r2-r5 in the same pass. Log with the existing
prefix `[ClassGrant] state=granted source=paladin …`.

**Players (new core code):** trigger in `Player::GiveLevel` (`Player.cpp:3832`) and
as a login catch-up next to `LearnFunserverTalentSpells`
(`CharacterHandler.cpp:885-887`, idempotent pattern `Player.cpp:23312-23326`). Log
`[ClassGrant] state=granted source=player …`, so one grep covers both.

**Trainer variant ("spell at the trainer"):** adding the rank-1 teach spells to the
**existing** trainer lists would let Alliance paladins and Horde shamans skip their
quests (`npc_trainer` has no race column) - not recommended. The **new**
off-faction trainers (§3.5) can carry their own list = class list + rank-1 / Sense
Undead / Warhorse / Charger teach spells; the totem items still need the bag grant.
Side effect [V code]: the bot trainer scan reads every class trainer, so Alliance
paladin bots would also find Redemption r1 there (harmless).

### 3.7 Class-quest gear for off-faction classes (owner decision D6, 2026-10-04)

Owner, verbatim: "auch zu spielen oder per post" ([#379 issuecomment-5979979939](https://github.com/Cilverkrow/twow-repo/issues/379#issuecomment-5979979939)),
then refined via OB-00 the same day: an equivalent quest is "zu viel aufwand", and
"geegenstand per post wenn der bot es verkaugft auch okay".

**Decision: by mail only, once per character, from the matching level.** No
replacement quest chain, no protection against selling or destroying, no re-delivery.
The same delivery applies to players and bots of the off-faction pairs; a bot that
sells the item is fine.

**Affected rewards [V `item_template`, `quest_template`, cli484-db 04.10]:** all are
bind on pickup (`bonding = 1`) and have no carry limit (`max_count = 0`), so the
marker below is what prevents a second copy.

| Chain (own faction today) | Quests | Mail at level | Reward |
|---|---|---|---|
| Paladin "Tome of Valor / Test of Righteousness" (589) | 1650 → 1651 → 1652 → 1653 → 1654 → 1806 (6) | 20 | 9607 Bastion of Stormwind (shield, class 2); 6953 Verigan's Fist (2H mace, class 2) |
| Paladin "Mightstone" (589) | 8415 → 8414 → 8416 → 8418 (4) | 50 | choice 20504 Lightforged Blade / 20505 Chivalrous Signet / 20512 Sanctified Orb (20620 Holy Mightstone is only the chain's tool, not mailed) |
| Shaman "Vortalus" (Turtle, 434) | 41938 → 41939 (2) | 20 | choice 58127 Hammer of Earthfury / 58128 Axe of Raging Winds / 58129 Claw of Tempered Fire |
| Shaman "Da Voodoo" (434) | 8410 → 8412 → 8413 (3) | 50 | choice 20369 Azurite Fists / 20503 Enamored Water Spirit / 20556 Wildstaff |

Chain quest items (7083, 6993, 18746) are only needed inside the chains and are not
mailed.

**Mechanism (Phase B, part of B7) [D]:**
- **Trigger:** level-up to (or login at or above) the mail level, only for the
  off-faction pairs (D3: Horde paladin, Alliance shaman). Shared hook with the spell and
  totem grants of B7.
- **Mail:** system mail from the class trainer of the own faction (D11 NPC) with the
  item(s), a short own text ("Your order has sent you …"). Paladin L20 sends both items
  in one mail.
- **Marker (once per character):** when the mail is created, the original final quest
  (1806, 8418, 41939, 8413) is set to rewarded for that character
  (`character_queststatus`). The hook sends nothing when the marker is set, so relogs,
  level-down/up or a later code run never send a second copy. No other state is needed.
- **No re-delivery:** a deleted, sold, returned or expired mail (30 days) or item is not
  replaced (owner). The marker stays set.
- **Choice rewards** (Mightstone, Vortalus, Da Voodoo): the mail carries **one** item.
  Recommendation: picked by the talent tree with the most points at the mail level
  (paladin: Holy → 20512 Orb, Protection → 20505 Signet, Retribution → 20504 Blade;
  shaman L50: Elemental → 20503, Enhancement → 20369 Fists, Restoration → 20556 Wildstaff;
  shaman L20: Elemental → 58129, Enhancement → 58128, Restoration → 58127); without talent
  points the first option. Alternative: all three items (more than the quest gives).
  **Small open point for OB-00/owner (D6b)**; Phase B assumes "one by spec".
- **Full mailbox / offline:** mail is created on the next login when it could not be
  sent (deferred, same as the totem retry, D13).
- **Effort:** S–M within B7 (hook, mail creation, marker, contract; no world data except
  the D11 trainer as sender). **Risks:** low; a lost mail costs the player the item
  (accepted by the owner); the marker must be written in the same transaction as the
  mail (contract checks the order).

**Rejected:** equivalent own-faction quest chains (owner: "zu viel aufwand").

## 4. Bot side

### 4.1 Factory and contracts

| # | File | Change |
|---|---|---|
| F1 | `RandomPlayerbotFactory.cpp` ctor (l.37-157) | `CLASS_PALADIN` + `RACE_TAUREN`; `CLASS_SHAMAN` + `RACE_NIGHTELF`, `RACE_HIGH_ELF`; comment `twow-repo#379 train 10`; outside `#ifndef MANGOSBOT_ZERO` |
| F2 | `t/race_class_availability_source_contract_tests.cmake` | expected set + `6,2 4,7 10,7`; add the new migration file to the parse list |
| F3 | new `sql/database_updates/<ts>_world.sql` + own contract modelled on `t/check_race_class_379_contract.cmake` (registered `CMakeLists.txt:1108-1111`) | the three pairs; never edit `20260927120000_world.sql` |
| – | `isClassForTeam` (l.261-270), group fill `PlayerbotMgr.cpp:3002`, `isRaceForTeam` (l.245, `RACEMASK_ALLIANCE` includes high elf, `SharedDefines.h:64`) | no change [V] |

Without F1, `AiPlayerbot.ClassRaceProb.2.6 / 7.4 / 7.10` are rejected at config
load ("that class cannot be that race. Ignoring it", `PlayerbotAIConfig.cpp:582-598`)
and the factory creates nothing [V]. Without F3 and with F1, `Player::Create` fails
(`Player.cpp:918-922`); F2 blocks that in CI.

### 4.2 Strategies, talents, roles [V]

- `strategy/paladin/*`, `strategy/shaman/*`, `AiFactory.cpp`, `Talentspec.cpp`,
  `ChangeTalentsAction.cpp`, `PersistentRosterTalentSpecPolicy.h`,
  `SpecAuraPolicy.h`, `ClassGrantPolicy.h`: **no race reference**. Premades are keyed
  per class/index (`PlayerbotAIConfig.cpp:1452-1463`; repo
  `deploy/roster/respec/premade-spec-index.tsv`). The new pairs inherit tank/heal/DPS
  behaviour unchanged.
- Shaman tank SpecAura (`TalentClasses = 4,7`) and shaman swords (race 0x7FF) apply
  to NE/HE shamans.
- Racials: `strategy/generic/RacialsStrategy.cpp:15-19` casts by name if known. War
  Stomp works for 6/2; Shadowmeld is commented out; the Turtle shaman racials are not
  used by any strategy.
- Roles: roster roles come from `deploy/roster/plan-360/spec-roles.tsv` (race-free).
  `isAvailableRole` (l.173-199) still says shaman = healer/DPS only; it is used only
  by the ad-hoc group fill. Optional cosmetic fix (D17).

### 4.3 Gear, mounts, start outfit [V]

- `RandomItemMgr.cpp:1063-1096` filters by team, `:1355` by class; no per-race
  filter. Class items that exclude the new races: 18864 (paladin insignia) and 51831
  Glyph of the Spectral Wolf (shaman, race 162); D14. No gear code change.
- Paladin off-hand = shield (`PlayerbotFactory.cpp:2654`), class-based.
- Mounts by race: tauren → kodo, NE → saber, high elf → default branch (horse).
  Paladin class mounts only through the grant (D5).
- Roster bots get their starter outfit from `playercreateinfo_item`
  (`RandomPlayerbotMgr::ProvisionPersistentRosterStarterOutfit`, l.4600).
- Totem items: `InitReagents` (`PlayerbotFactory.cpp:4723`) hands out every
  `Totem[]` item of each known spell (`:4829-4844`), race-agnostic; it needs a known
  totem spell first (rank 1 from ClassGrant).

### 4.4 Roster generator (OB-40, #518/#521)

- `select_roster_v5.py`: `ALLIANCE=(1,3,4,7,10)`, `HORDE=(2,5,6,8,9)` (l.46-47);
  pairs only from `--catalog` filtered by `--catalog-sources` (default
  `live,new-178,new-165`, l.605) [V].
- Add `6 2 new-379`, `4 7 new-379`, `10 7 new-379` to
  `deploy/roster/plan-360/race-class-catalog.tsv` (61 rows, none of the three) and
  `new-379` to the sources; `NEW_PAIRS` in `test_select_roster_v5.py:24` [V].
- **`--rare-pairs` must be extended explicitly** to `3:7,3:9,5:2,6:2,4:7,10:7`. The
  list is a parameter, not derived from the catalog, so new pairs are **not** capped
  automatically (OB-40 review of this PR, comment 5979961572) [V].
- **Cap rule as coded** (`select_roster_v5.py:266-289`) [V]: per rare pair
  `limit = max(ceil(rare_share × half), floor, pair_count)`, where the floor covers
  every role (`cell_min × roles`) and, for a healer class only rare pairs provide,
  its share of `--healer-min` / `--healer-min-new`. The rule is **symmetric**; there
  is no faction-specific precedence.
- **Consequence:** once 6/2 joins 5/2, **every** Horde paladin and **every** Alliance
  shaman comes from a capped pair. The floors (healer minimum, `--healer-min-new 1`,
  a paladin and a shaman tank per guild, #518) then set the class size, not the
  2.5 %. OB-40's simulation with the train-10 pairs (`finalsim\`, #518 comment
  5979151114) gives 2.7-3.5 % per rare pair, above the cap.
- **Per-pair split with the train-10 pairs and cap** (OB-40 dry run
  `evidence\ws-60\ob40-518-roster-800\finalsim\`: `--rare-share 0.025`,
  `--cell-min 1`, `--healer-min g`, `--healer-min-new 1`, warriors ×2; OB-40 review
  comment 5979961572):

  | Stage | Undead paladins (share of undead) | Tauren paladins | Horde paladins (share of Horde) | Alliance shamans (share of Alliance) |
  |---|---|---|---|---|
  | 270 | 4 / 27 (15 %) | 4 | 8 (5.9 %) | 12 (8.9 %) |
  | 810 | 14 / 81 (17 %) | 11 | 25 (6.2 %) | 34 (8.4 %) |

  Per role at 810: undead paladin T 9 / H 2 / D 3, tauren paladin T 2 / H 7 / D 2.
  Paladin healers come mainly from the tauren, paladin tanks mainly from the undead
  (tank class weighting + healer floor).
- **Undead paladins (owner question "zu viele untote Paladine?", #518):** uncapped,
  the share among undead is 30 % today and 22 % with the new pairs at 270, 31 % at
  810 (comment 5978827314). With the cap on 3:7, 3:9, 5:2 only: 19 % at 270, 14 % at
  810 (comment 5979151114). With the train-10 pairs and cap: **15 % at 270, 17 % at
  810** (table above).
- **Factory volume** for the three new pairs (from `demand-p1` per stage, incl. the
  gender margin): 270: 36, 360: 18, 450: 18, 540: 18, 630: 18, 720: 20, 810: 20.
  Recommendation (OB-40): one factory run per main train, covering the stages up to
  the next main train, instead of a maintenance factory start per stage.
- **Professions:** no generator change. Leatherworking is allowed for 4/7 and 10/7
  (shaman = leather class); 6/2 takes the paladin preferences (Herbalism/Alchemy,
  Mining/Jewelcrafting).
- Owner wording "durch horde stärkere vertretene kombinationen den vorrang zu
  gewähren" is ambiguous → D12.
- **Names** come from OB-40 as an extension of the #518 list before the factory run
  (#518 comment 5979464139), under the #518 rule (unique against all first and last
  names in `deploy/roster/names-518/rp-names-810.tsv`, English "of <place>"). The 90
  new bots of stage 270 already have planned names per ordinal / race / class /
  gender; with the train-10 pairs the race/class of some ordinals changes, so the
  extension replaces exactly those rows. The owner sees the list first.
- `guild_plan.py` (`HORDE={"2","5","6","8","9"}`) is correct for race 10 [V].

### 4.5 Guild fill (CLI-485, core#281 open draft)

Faction via `Player::TeamForRace`, correct for race 10; the guild note uses class,
spec tab and tank flag - no pair logic, no change [V diff]. **RareComboSpread needs
no pair list:** `guild_plan.py --rare-spread` (repo PR #525) works over **all**
race/class pairs with at most ceil(count / guilds) per guild and is harmless for
common pairs, matching the core#309 description ("every race-class combination at
most ceil(count / guilds) per guild"). The new pairs are therefore covered without a
config change, as long as core#309 stays as described (OB-40 review comment
5979961572).

### 4.6 Factory run

**Binding procedure: `deploy/roster/plan-360/README.md` l.86-111** ("Candidates for
the new pairs"). One start only, with OB-40/OB-00 and individual approval (DB
mutation), with exactly these overrides:

```
AiPlayerbot.PersistentActiveRoster.Enabled = 0
AiPlayerbot.RandomBotAutologin = 0
AiPlayerbot.RandomBotAutoCreate = 1
AiPlayerbot.DeleteRandomBotAccounts = 0
AiPlayerbot.RandomBotRandomPassword = 1
AiPlayerbot.RandomBotAccountCount = <base + ceil(sum FACTORY / 9)>   # base: see below
AiPlayerbot.ClassRace.UseFixedClassRaceCounts = 1
AiPlayerbot.ClassRaceProb.2.6 / 7.4 / 7.10 = <FACTORY>   # every other ClassRaceProb key removed
```

The factory fills only accounts with fewer than 9 characters, and it deletes
temporary bots and empty rndbot accounts: pre-check (read-only) no `bot_delete` and
no `temporary` events. Non-roster random bots: keep the three keys absent so the pairs
stay rare [A].

**`RandomBotAccountCount` base (OB-40 review 5979961572):** the README says
"current"; in train 7 the base was the **profile value** (500 in the example
profiles, `500 + ceil(sum / 9)`), not the live account count. To avoid a factory that
creates too few or no accounts, the base is
`max(profile value, live number of RNDBOT accounts from the OB-40 snapshot pre)`; OB-40
fills in the number from the `pre` snapshot and confirms the formula before the window
[D].

**Gender:** the factory picks the gender at random. `demand.tsv` therefore asks for
twice the larger gap + 4 (generator rule); the female share (`--female-share 0.55`)
comes from the pool selection, not from the factory [V OB-40].

**Order** (as in train 7, `ob40-train7-wave1/gen.sh`; OB-40 review 5979961572):

1. world migration (B1) → image with F1/F2;
2. **rollback preparation:** ROLLBACK request to the previous roster version + cold
   backup (as in train 7);
3. **OB-40 snapshot `pre`**;
4. factory window (overrides above, individual approval);
5. **OB-40 snapshot `post-factory`** (real GUIDs of the new characters; the factory
   characters stay offline and untouched);
6. **generator phase 2** (final plan, hashes);
7. **REPLACE / EXPAND / ROLLBACK requests** (`make_*_request.py`), applied in the
   maintenance window;
8. A5 rename (name extension, own hash) → A6 respec → reset-l1;
9. **`guilds.tsv`** for the core#309 PlanFile;
10. start.

## 5. Client for players

### 5.1 Who decides creation

- **Server [V]:** `HandleCharCreateOpcode` (`CharacterHandler.cpp:225-273`) checks the
  creation-disabled mask, faction balance, ChrRaces/ChrClasses existence and the
  not-playable flag. It has **no pair check**; `Player::Create` fails only without a
  `playercreateinfo` row. No server code reads CharBaseInfo or CharStartOutfit (0
  `git grep` hits; bindings `server_loaded = false`).
- **Consequence [V]:** a modified client can create 3/7 and 5/2 today, and after B1
  also 6/2, 4/7 and 10/7. Such a player character has no trainer and, until B7, no
  grants. Whether to allow this or gate player creation of these pairs until v9 is
  D18.
- **Client:** `CharacterCreate.lua` builds the class buttons from
  `GetClassesForRace()` (:94, :243); `MAX_CLASSES_PER_RACE = 8` (:3), more gives "Too
  many classes!" (:152-154); the XML defines buttons 1..8 [V]. That
  `GetClassesForRace()` reads CharBaseInfo is community knowledge [A]; Turtle's own
  pairs exist only as appended CharBaseInfo rows [V]. Confirm with a one-row probe.
- **Bots** are created server-side; other clients only display race/class [A].

### 5.2 Deltas (Phase B, files not written)

| File | Content |
|---|---|
| `changes/CharBaseInfo/0379_race_class_pairs.csv` | 5 `insert` lines: `3:7`, `5:2`, `6:2`, `4:7`, `10:7` (composite-key insert supported: `delta.py:141-158`, `tests/test_delta.py:81-84`) |
| `changes/CharStartOutfit/0379_start_outfits.csv` | 10 rows (5 pairs × 2 sexes), ids 137-146 (base max 136) in the order 3/7, 5/2, 6/2, 4/7, 10/7; `copy:<template>` + RaceID + swapped food (and for 6/2 the cleared feet slot, §2.1 C2); templates orc shaman 21/22, human paladin 3/4 |
| optional `changes/SkillLineAbility/0379_shaman_racials.csv` | race mask of exactly 5075/5076/5077/6187 widened by the granted races (D7), mirrored with `sql:` from a server `skill_line_ability` migration. **This variant is "client patch + SQL companion under the same version"** (pipeline §5.5): the migration must be live first (main train, Ä15) and in the export used for the build |

No SRCI, TalentTab, ChrRaces, ChrClasses or glue delta. Classes per race after
#379: **dwarf 8 = the glue limit**, undead 7, high elf 7, tauren 6, night elf 6 [V].

CharStartOutfit is cosmetic (creation preview); orphan base rows (9/2, 10/9, race
11) show it enables nothing [V].

**Supersession:** `docs/design/client-patch-pipeline.md` Stage 3 (l.1076-1100) still
plans an SRCI patch with `skill_race_class_info_mod` rows and a possible glue
override for #379. This design replaces that: no SRCI, no glue, CharBaseInfo +
CharStartOutfit for five pairs, R-CBI-1. Follow-up (B9): edit Stage 3 scope and
acceptance accordingly.

### 5.3 Consistency rules [D, OB-15]

- **R-CBI-1 client pairs ⊆ server pairs** (fail closed): every CharBaseInfo pair has
  a `playercreateinfo` row. Needs a tool change: `consistency.py:127-128` refuses
  composite keys, and the SQL loader parses every key as an integer
  (`sqlsrc.py:110`), so the source key must be numeric, e.g.
  `SELECT race*100+class AS k FROM playercreateinfo`, plus a kind `pairs_in_sql` (or
  key mapping) on the DBC side [V].
- **R-CBI-2 server pairs ⊆ client pairs**: informational; after #379 the difference
  is empty.
- **R-CSO-1 outfit items exist**: **not possible without code change**. CSO pads
  empty slots with ItemID −1; `refs_in_sql` skips only falsy values
  (`consistency.py:139`, `if v and …`), so every −1 slot becomes a finding, and
  accepts per row key would hide real findings. `sql/sources.toml` has no
  `item_template` source. Either a new source + "ignore values ≤ 0" in the tool, or
  manual review in `review.csv` (recommended for train 10).
- Outfit food == `playercreateinfo_item` food: manual review in `review.csv`.

### 5.4 Coupling and patch numbering

- **Numbering is not settled [V PR titles]:** #503 shipped as patch 7 "v6.1"; #488
  (riding, train 9) says "Patch v7"; #512 (talents) and #514 (sword masks) say
  "patch 8". All three are open. This design names the #379 release "v9" after the
  owner; OB-15 assigns the final number. B9 depends on "the train-9 client patch(es)
  with #488, #512, #514 merged", whatever their number.
- #379 adds the new directories CharBaseInfo/CharStartOutfit; only the optional SLA
  delta shares a directory with #514/#488 (disjoint keys). Prefix files `0379_`.
  `consistency/server.toml` edits are append-only (#512 edits it too; #512 does not
  touch `sql/sources.toml`) [V PR files].
- **Server DBCs:** the build writes `server-dbc/` for every changed server-loaded DBC
  (`build.py:315-322`); `main` already has Talent and SpellItemEnchantment deltas,
  #488 adds SkillRaceClassInfo. A #379 build therefore emits Talent,
  SpellItemEnchantment and SkillRaceClassInfo (plus whatever train 9/10 add). "No
  server DBC deploy for #379" holds only if these are **byte-identical** to the
  deployed set (OB-30 compares as in #503). The build needs a pristine
  `--server-dbc` directory, not the live `data/dbc` after the coupled train-9 deploy.
- The DBC part of #379 (CharBaseInfo, CharStartOutfit) is client-only; the SLA
  variant of D7 is not (§5.2).
- **Never ship CharBaseInfo rows before the server rows are live**, otherwise the
  button gives a create error (no crash) [V `Player.cpp:918-922`].

## 6. Risks and test plan

### 6.1 Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Server exits at start (`LoadPlayerInfo`, missing levelstats) | levelstats first, `playercreateinfo` last, CHECK tail; disposable-DB dry run; test-stack start before live |
| R2 | Allow-list merged without data → factory "Unable to create random bot" | F1 and F3 in one PR; availability contract (F2) |
| R3 | Factory window creates wrong pairs, deletes bots or accounts, or runs out of account slots | README l.86-111 binding (§4.6): only the three `ClassRaceProb` keys, `DeleteRandomBotAccounts = 0`, `RandomBotAutologin = 0`, account count + 9-per-account limit, pre-check for delete/temporary events; count created bots against FACTORY; 0 lost bots (ADR-0031) |
| R4 | Silent capability gap: Horde paladins without Redemption/mounts, Alliance shamans without totems or racials look healthy in logs | acceptance checks `character_spell` and `[ClassGrant]` lines (§6.4) |
| R5 | ClassGrant only for persistent-roster bots | acceptable, only the roster is live [A] |
| R6 | High elf faction bug (`IsAlliance`) | hotfix 8.21 (OB-20), before the factory run |
| R7 | Changing earth 4 → 5 shifts all shaman bots | prefer 4; else test update in B3 |
| R8 | CharBaseInfo before server rows → create error | R-CBI-1, order rule §5.4 |
| R9 | Rollback after bots exist | before the factory run: delete the new pair rows (additive migration); after: never remove `playercreateinfo` of pairs with characters [A]; disable only the allow-list and keep data. Character deletion = individual approval |
| R10 | Race change: `GetShamanSpellForRace` maps dwarf/NE/HE shamans to 0, so their racials are neither removed nor converted; `ChangeSpellsForRace` (`Player.cpp:~23856`) is untested for the new pairs | block race change into/out of the new pairs until reviewed (D15) |
| R11 | Dwarf at 8 classes = glue limit | no further dwarf class without glue override |
| R12 | Free riding with the paladin class mount (after #295 only 50 s / 5 g value; warlocks already get it) | D5b; `UpdateOldRidingSkillToNew` gives riding even for a direct 13819/23214 grant |
| R13 | Patch collides with other train-10 client work (own maps #427) | one builder (OB-15), append-only README/config rows |
| R14 | Off-faction shaman destroys a BoP totem → element lost for good | re-grant when missing (D13) |
| R15 | Player characters of bot-only pairs created with a modified client (no trainer, no grants) | D18 |
| R16 | Rare cap above 2.5 % because floors win | D12; report class-level shares in the OB-40 dry run |

### 6.2 Disposable-DB dry runs (before any PR leaves draft)

1. Apply the new world migration to a fresh copy of `tw_world_main` **twice**
   (replay-safe).
2. `SELECT race, class, COUNT(*) FROM player_levelstats WHERE (race,class) IN ((6,2),(4,7),(10,7)) GROUP BY 1,2`
   → 60 each; spell counts 39/41/40; action and item counts as §2; all values 1..255.
3. Negative case: remove one levelstats row before apply → CHECK tail fails, no
   `playercreateinfo` row written.
4. `skill_race_class_info_mod` unchanged (3 rows: 132, 90043, 90055; + 890 if #488
   is in).
5. Trainer migration (B8): new `creature_template` rows load, `npc_trainer` /
   template row counts 159/176, spawns friendly to the target faction (FactionTemplate
   check).

### 6.3 Contracts (CI)

- New migration contract (exact rows, LF, only the three tuples, guards, tail).
- `race_class_availability_source_contract` extended (F2).
- `class_grant_policy_tests.cpp` + `class_grant_source_contract_tests.cmake`
  (registered `modules/mod-playerbots/tests.cmake:661`) with the paladin rows and
  Table B.
- World-data contract: rank-1 teach spells still quest-only, `spell_chain` prev as
  expected.
- `check_dwarf_shaman_racials_contract.cmake` updated if the bypass is generalised
  or replaced by SLA rows.
- `IsAlliance` contract (B4).

### 6.4 Acceptance (Akzeptanzleiter: CI → merge → pin → deploy → measured)

**Bots (test stack first, owner approval; then live factory window):**

| Measure | Target |
|---|---|
| Server start with train-10 world | 0 `LoadPlayerInfo` errors, no `exit(1)` |
| Factory run | 1 bot per pair on the test stack; on live exactly the FACTORY counts; no deleted bots or accounts |
| Start state | start zone, `_item` outfit, racials (War Stomp 20549 for 6/2) |
| Level 12/20/40/60 (GM `.levelup` on the test realm) | paladin: 7328, 5502, 13819, 23214 in `character_spell`, riding as decided in D5b, Redemption r2+ from the scan; `[ClassGrant] source=paladin` lines |
| Level 4/10/20/30 | shaman: items 5175-5178, spells 8071/3599/5394, `[ClassGrant] source=totem`; Ghost Wolf at 20, Mail at 40 |
| Lost totem | destroy 5175 on a test bot → back after the next grant pass |
| Racials | Hex/Feral Spirit/Ethereal Form exactly as decided (D7) |
| Behaviour | one dungeon group with a tauren paladin tank/healer and an NE/HE shaman healer; War Stomp used |
| ADR-0031 | 0 lost bots, tick budget unchanged, level progress of the new bots comparable within the same roster phase |

**Players (patch probe on the owner's PC, full client restart, not `/reload`):**

1. Build twice, byte-identical; `review.csv` exactly 5 CharBaseInfo + 10
   CharStartOutfit inserts (+ optional 4 SLA rows); `undeclared.csv` empty; R-CBI-1
   PASS; `server-dbc/` byte-identical to the deployed set.
2. For each of 3/7, 5/2, 6/2, 4/7, 10/7: button visible, preview outfit (tauren
   paladin without boots), create, log in, start zone.
3. Spellbook: three class tabs and Shield for both classes; **paladin** Mail from
   L1, Plate from L40; **shaman** Mail from L40, totem spells castable with the
   totem items in the bag; dwarf shaman racials shown as decided.
4. Dwarf shows 8 class buttons without "Too many classes!".
5. Off-faction trainer reachable and friendly (D11), grant at the decided levels,
   full-bag case (deferred, then granted after freeing a slot).
6. Without the patch: old creation screen, no errors. Rollback: catalog back to the
   previous version; no server DBC rollback for #379.

## 7. Effort and order

Sizes: S ≤ 0.5 day, M 1-2 days, L ≥ 3 days of agent work, excluding review waits.

| Phase | Content | Repo / owner | Size | Depends on |
|---|---|---|---|---|
| B0 | owner decisions §8, OB-20 review | OB-00 / owner | – | this PR |
| B1 | world migration 6/2, 4/7, 10/7 + contract (F3) | core, CLI-379 | M | train 9 assembled; main train 10 (Ä15) |
| B2 | factory allow-list + availability contract (F1, F2), same PR as B1 | core | S | B1 |
| B3 | Table A for bots (paladin rows, + earth level if D2 = 5) | core | S-M | D2-D5 |
| B4 | `IsAlliance` + high elf (pre-existing bug) | **hotfix 8.21, OB-20** (not in this work) | S | none; no DB |
| B5 | Table B racials for bots; `GetShamanSpellForRace` tauren 45500 → 45502; optional `skill_line_ability` race-mask migration (tauren script fix 47262 → 47341: hotfix 8.21, OB-20) | core | S-M | D7 |
| B6 | roster: catalog rows, `--rare-pairs`, names extension, factory window, A5/A6 | repo, OB-40 / OB-00 | M | B1+B2 deployed, names approved, D12 |
| B7 | player grant hook (level-up + login, deferred full-bag case), class-quest gear by mail (§3.7: once per character, quest marker, no re-delivery), optional D18 creation gate | core | M | D3, D4, D5b, D6, D13, D18 |
| B8 | off-faction trainers (D11 table): `creature_template`, `npc_trainer`(_template), `creature` spawns; **also closes the gap of 5/2 and 3/7 today** | core world SQL, OB-20 | M | D4, D11 (owner GPS check); first main train with approval, not "players last" |
| B9 | client deltas + R-CBI-1 tool extension (numeric key) + probe build + pipeline Stage 3 edit | repo, OB-15 | M | train-9 client patch (#488/#512/#514) merged; B1 in the export DB; D1, D10 |
| B10 | acceptance §6.4, release notes | OB-30 / OB-00 | S-M | all |

**Bots first:** B1+B2+B3 (+B5) in train 10, then B6. B4 (`IsAlliance` + high elf) and
the tauren script fix (47262 → 47341) are **not** part of this work: OB-20 ships them
as **hotfix 8.21** (OB-00, 04.10). **B8 trainers earlier** (OB-20 review 5979966747):
the existing pairs 5/2 and 3/7 have no player trainer today either (§3.5), so B8 closes
an existing gap and should not wait for "players last"; it can ship with the first main
train that has the D11 approval. **Players, collectively:** B7+B9 together (+B8 if not
shipped earlier). B7/B8 are server changes and may ship in train 10 inactive for players
until the client patch is released; B9 is built last against a world export that
already contains the train-10 pairs.

## 8. Owner and OB decisions

**Owner decisions of 2026-10-04** ([#379 issuecomment-5979979939](https://github.com/Cilverkrow/twow-repo/issues/379#issuecomment-5979979939), verbatim "auch zu spielen oder per post" (D6), "rest wie emfpohlen"):

- **D6 decided differently from the recommendation:** class-quest gear for off-faction
  classes comes **by mail only**, once per character from the matching level, with a
  marker against a second mail; no replacement quest ("zu viel aufwand"), no protection
  or re-delivery if a bot sells it → §3.7. Open detail D6b: choice rewards (one by spec
  recommended).
- **All other decisions as recommended:** D1 (bots in train 10, players when grant,
  trainers and client are ready), D2 4/10/20/30, D4, D5a/D5b (free riding as parity),
  D7 (one rule for all Alliance shamans), D10, D11 (OB-20 table, **earlier**), D12 ((b),
  floors may exceed 2.5 %), D13 (re-grant); D3, D14, D15, D18 as in the OB-20 review.
- **D7 follow-up [open, OB-00]:** "one rule" leaves open whether that rule is *all three
  racials* (continuation of the 2026-09-27 decision) or *none* for dwarf, night elf and
  high elf shamans. Phase B assumes **all three** (no change for the dwarf) unless the
  owner says otherwise.
- Bugs 47262 and `IsAlliance`/high elf: hotfix 8.21 (OB-20).

The table below keeps the options for reference.

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Players get the pairs in train 10 or later | train 10 / later train | bots in train 10; players only when B7+B8+B9 are ready together |
| D2 | Totem levels | earth 4 or 5; fire 10, water 20, air 30 | **4/10/20/30** = Horde quests = bot table |
| D3 | Grant scope | only pairs that cannot take the quest / all races of the class | only off-faction pairs |
| D4 | Paladin rewards | auto-grant 12/20/40/60 / spells at new Horde trainers (fee) | grant Redemption 12, Sense Undead 20; mounts per D5 |
| D5a | Paladin class mounts for Horde paladins | (a) Warhorse 40 / Charger 60 as is; (b) tauren get normal kodos 18990 / 23249 instead; (c) new "sunwalker kodo" (Spell.dbc + creature, client work) | (a) for train 10; (c) not in train 10 |
| D5b | **Free riding with the class mount** (33388 at 40, 33391 at 60; after #295 the trainer value is only 50 s / 5 g) | yes, parity with Alliance paladins and warlocks / no (needs a core change in `UpdateOldRidingSkillToNew` and a grant of 13819/23214 without the teach spell) | **yes (parity)**, OB-20 agrees (5979966747): small value after #295, warlocks already have it, no special rule for mount speed; owner confirms |
| D6 | Gear rewards: 9607 Bastion of Stormwind, 6953 Verigan's Fist, 8418 Mightstone choices 20504/20505/20512, 41939 Vortalus choices, 8413 Da Voodoo choices; chain items 7083, 6993, 18746 (quest items, no grant needed) | none / playable / by mail | **decided 04.10: by mail only**, once per character with a marker, no replacement quest, no re-delivery (§3.7); D6b open: choice rewards one by spec (recommended) or all three |
| D7 | **Shaman racials.** Owner 2026-09-27, verbatim: "Zwergen-Schamane bekommt alle drei Horde-Rassenfähigkeiten der Schamanen: Hex (Troll, 45504), Feral Spirit (Ork, 45505/45514), Ethereal Form (Tauren, 45502) („weil er alleine für die Allianz steht“)". With NE and HE shamans the dwarf is no longer alone. | Q1: does the 09-27 decision still apply? Q2: if yes, NE/HE also all three, or none? Q3 **answered (OB-20 5979966747): the tauren racial is Ethereal Form 45502** (client SLA 6187 race 0x20, quest wording "spiritwalking"); `GetShamanSpellForRace` → 45500 is inconsistent and moves to 45502 in B5. Q4: script fix and Table B rows for Horde bots (troll 47263, tauren 47341) in any case; the script fix ships as **hotfix 8.21 (OB-20)** | owner for Q1/Q2; OB-20 recommends one rule for all Alliance shamans (all three or none) |
| D8 | High elf shaman stats | A human offset / B orc copy / C A + 10/2 spirit delta | A (C if the owner wants the HE spirit flavour) |
| D9 | Tauren paladin stats | human paladin + priest offset / dwarf paladin + warrior offset | priest offset |
| D10 | Start outfits and food | class kit of the template; tauren 4540 or 4604; NE 4536 or 117; HE Primitive or Initiate set; tauren paladin preview without boots | class kit; 4540; 4536; Primitive; no boots in the preview |
| D11 | Player trainers | placement per OB-20 (table D11 below) | as proposed by OB-20; coordinates derived from neighbouring trainers, owner confirms them in the client (GPS) before the migration leaves draft; main train |
| D12 | Rare cap | Q1: what does "Vorrang" mean: (a) established undead paladin before the tauren paladin, or (b) the more common Horde pairs before all rare pairs (= the cap as coded)? Q2: may a floor (healer/tank per guild) lift a pair above 2.5 % (finalsim: 2.7-3.5 % per pair; Horde paladins 5.9 % / 6.2 %, Alliance shamans 8.9 % / 8.4 % of the faction at 270 / 810)? Q3: undead paladin share **15 % (270) / 17 % (810)** with the train-10 pairs and cap enough? (a) would need an asymmetric limit (`--class-role-max` or a per-pair share), not built | (b) and floors may exceed the cap, as #521 does |
| D13 | Lost totem for off-faction shamans | re-grant when missing / NPC or vendor / nothing | **re-grant when missing** (same as bots); "nothing" soft-locks them |
| D14 | Endgame gaps (§3.1, §3.2 tables): T0.5 upgrades, AQ20, AQ40, Darkreaver/Ossuary, PvP insignia | race-mask data fix (434/589 → 0 or wider) / accept / train 11 with raids | OB-20 rule question; recommend train 11 with the raid content |
| D15 | Race change into or out of the new pairs | allow / block until reviewed | block until reviewed |
| D16 | Fix the #379 wording | dwarf warlock is a player pair already | OB-00 |
| D17 | Shaman as TANK in `isAvailableRole` (group fill only) | yes / no | optional, low priority (OB-10) |
| D18 | Player creation of client-unknown pairs before the client patch (modified client) | allow / gate in `HandleCharCreateOpcode` for `SEC_PLAYER` until the patch | owner/OB-20; gate is a small core change |

**D11 trainer placement (OB-20 proposal, review 5979966747; implemented in B8):**

| Class | City / start | Place | Faction template |
|---|---|---|---|
| Paladin | Thunder Bluff | Spirit Rise, near the priest and mage trainers (sun theme, An'she) | as the TB trainers (104) |
| Paladin | Camp Narache | with the class trainers at the longhouse | 104 |
| Paladin | Undercity | War Quarter, next to the warrior trainers | as the UC trainers (68) |
| Paladin | Deathknell | in the church with the class trainers | 68 |
| Shaman | Ironforge | Mystic Ward, near the priest and mage trainers | as the IF trainers (55) |
| Shaman | Coldridge Valley | Anvilmar, with the class trainers | 55 |
| Shaman | Darnassus | Cenarion Enclave, near the druids | as the Darnassus trainers |
| Shaman | Shadowglen | Aldrassil, with the class trainers | as Darnassus |
| Shaman | Alah'Thalas / high elf start | with the class trainers | 371 (as the high elf paladin trainers) |

Own NPC names (not lore names), titles "Paladin Trainer" / "Shaman Trainer" (tauren
paladin trainers e.g. a "Sunwalker …" first name), existing displays of the race; one
shared `npc_trainer_template` list per class (§3.5); rank-1 teach spells only at these
new trainers ("spell at the trainer" variant), not at the existing ones. Coordinates:
OB-20 derives them from neighbouring trainer spawns in the disposable DB; the owner
confirms them in the client (GPS) before the migration leaves draft.

## 9. Open questions (not resolved by data)

1. `GetClassesForRace()` ← CharBaseInfo [A]: one-row probe (OB-15).
2. Spellbook / trainer display of a spell whose client SLA row excludes the race
   (dwarf shaman racials) [A]: probe.
3. Live values of `AutoLearnTrainerSpells`, `AutoLearnQuestSpells`,
   `ClassGrant.Enabled` equal the canonical config [A].
4. **Answered:** tauren have no working path to Ethereal Form; the quest script
   teaches the non-existent 47262 (§3.4; fix in hotfix 8.21, OB-20). Open: what live tauren shamans actually have
   (read-only `character_spell` count by OB-40) [A].
5. Faction 1698 of the Turtle shaman trainers is Horde [A].
6. Tauren ChrRaces flag bit 0x2 = no feet geoset [A].
7. **Closed:** high elf food display ids are 29439 (80250) and 1483 (80251) [V].
8. Load path of characters whose pair loses its `playercreateinfo` row [A].
9. Effect of `AllowTwoSide.Interaction.Group` on the high elf `IsOpposing` bug [A].
10. Whether Turtle adds a totem bar to the 1.12 UI [A].
11. Vanilla recovery of a lost totem for Horde shamans (quest-giver gossip?) [A].

### Contradictions between the research reports, resolved

| Topic | Reports | Resolution [V] |
|---|---|---|
| Totem items from `InitReagents` | R3: none; R1/R4/R5: totem loop | loop at `PlayerbotFactory.cpp:4829-4844`; needs a known spell |
| Shaman trainer count | R3: 14; R4: 12 | 14 entries; 12 carry the full list |
| Paladin trainer count | R2: 13; R4: 10 | 13 (R4 omitted 925, 926, 80220) |
| Dwarf racials learnable | R1: trainer path passes; R4/R5: no source | check passes, but no trainer row except 45520 |
| Tauren food | R2: 4540; R6: 4604 | both exist; proposal 4540 (D10) |
| Quest 96 class | `ClassGrantPolicy.h:11-12` comment: no class requirement | `RequiredClasses = 64`; comment stale |
| Brief: 3/9 bot-only | brief, #379 text | 3/9 is in base CharBaseInfo and CharStartOutfit (39/40) |
| Totem spell counts | draft 19/22/17/13 | 19/34/17/15 with spellFamilyName 11 |

The review of the first draft (OB-20, OB-15, completeness) and its resolution are in
`work\G-review-resolution.md`.

## Appendix: evidence

All under `Y:\backup twwow\workspace-relocation-20260902\evidence\ws-30\cli379-race-class\`:

| File | Content |
|---|---|
| `Auftrag-Rasse-Klasse-379.md` | assignment |
| `work\issue-379.md`, `issue-518.md`, `issue-521.md` | issue texts incl. comments |
| `work\R1-existing.md` + `work\r1-tools\` | existing pairs, SRCI/SLA scan |
| `work\R2-tauren-paladin.md` + `work\r2-tools\` (`tauren-paladin-levelstats-derived.tsv`) | tauren paladin, 60 derived rows |
| `work\R3-elf-shamans.md` + `work\R3-tools\` + `work\R3-data\` (`derived-levelstats-4-7_10-7.tsv` sha256 `208ed46a…`, DBC TSV dumps) | elf shamans |
| `work\R4-class-quests.md`, `work\R5-bots.md`, `work\R6-client.md` + `work\r6-tools\` | class quests, bot side, client |
| `work\C-OB15-client-critic.md`, `work\C1-critic-completeness.md`, `work\c20-tools\`, `work\critic-tools\` | review of the first draft |
| `work\g-tools\g1..g5.sql/.out` | verification queries of this revision (riding effects, faction-locked quest list, trainer templates, conditions, displays, HE stats) |
| `work\G-review-resolution.md` | how each review point was resolved |

The DBC TSV dumps are local evidence and must not go into Git.

**Not verified:** anything live (DB, config, characters, bots); in-game behaviour of
the client (creation buttons, spellbook display, animations, mount look, preview
without boots); Turtle GlueXML beyond `CharacterCreate.lua/.xml`; whether
`LearnSpell(47262)` fails silently or logs; gossip text conditions 451-461; the
derived levelstats were not loaded by a server.
