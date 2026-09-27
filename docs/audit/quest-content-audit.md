# Static quest and content audit (twow-repo#408)

Status: analysis only. No fixes in this change. Nothing here was checked against the live
server; every statement comes from the data and code at the commits named below. Items
marked **verify live** are for the OB-20 read-only pass.

- twow-core `origin/main` @ `33210d80dafbb694dc2432523d1c1268b2b65d1b` (2026-09-27 21:06 +0200)
- World data: `sql/base` (191 files) plus all 171 migrations in `sql/database_updates/world/`
  and `sql/database_updates/*.sql`, merged by timestamp, imported into a disposable MariaDB
  10.11 in the cloud sandbox. Every migration applied without an error.
- A second schema with `sql/base` only, to tell gaps Turtle shipped from gaps the migrations
  made (marked **REGRESSION**).
- C++: `src/scripts`, `src/game`, `modules` (registered script names, entry/quest literals).
- Findings: [`quest-content-audit.csv`](quest-content-audit.csv), 908 rows.
- Reproduce: [`tools/quest_content_audit.py`](tools/quest_content_audit.py) (read-only
  SELECTs; the header says how to call it).

## Summary

6,708 quests in `quest_template`. 45 have `Method = 1` (disabled in the core) and 147 have no
giver at all (no questrelation and no starting item; players never see them). Of the
remaining 6,516:

| Verdict | Quests | Meaning |
|---|---:|---|
| OK | 6,013 | every check passed |
| OK_SUSPICIOUS | 171 | works only through a path the static check cannot prove (mostly C++ credit), or a non-blocking oddity |
| **BROKEN** | **93** | a player can take the quest but can never complete it |
| **PARTIAL** | **14** | completable, but a scripted part is missing (completion script) |
| UNOFFERED | 118 | the giver exists in the data but is never spawned, so nobody is offered the quest (+7 chain targets without any giver, see CHAIN_GAP) |
| EVENT_OFF | 107 | belongs to a `game_event` that is `disabled = 1` (Lunar Festival, Love is in the Air, Scourge Invasion, AQ war) |

On top of the quests, 77 content rows (bosses, instance entrances, instance scripts, script
registry) have no quest id in the CSV.

Findings per category (a quest can have several):

| Category | Quest rows | of which on BROKEN/PARTIAL quests | Content rows |
|---|---:|---:|---:|
| SPAWN_GAP (creature/GO missing) | 465 | 43 | 23 |
| ITEM_GAP (no item source) | 86 | 59 | - |
| SCRIPT_GAP (script missing) | 28 | 23 | 43 |
| BROKEN (no ender, missing spell) | 8 | 7 | 2 |
| CHAIN_GAP | 8 | 1 | - |
| OK_SUSPICIOUS | 236 | 4 | 9 |

BROKEN / PARTIAL / UNOFFERED quests per zone (zones with at least one BROKEN or PARTIAL):

| Zone / sort | BROKEN | PARTIAL | UNOFFERED |
|---|---:|---:|---:|
| Alterac Valley | 16 | 0 | 0 |
| The Barrens | 5 | 7 | 24 |
| Moonwhisper Coast | 9 | 1 | 4 |
| Deadwind Pass (Karazhan tier turn-ins) | 9 | 1 | 1 |
| Timbermaw Hold | 7 | 0 | 2 |
| Northwind | 6 | 1 | 1 |
| Rogue (class chain) | 5 | 0 | 1 |
| Moonglade | 4 | 0 | 1 |
| Grim Reaches | 4 | 0 | 0 |
| Stormwind City | 3 | 0 | 3 |
| Duskwood | 3 | 0 | 1 |
| Venture Company Camp | 3 | 0 | 3 |
| Balor | 3 | 0 | 0 |
| Warlock (class) | 2 | 0 | 3 |
| Winterspring | 2 | 0 | 0 |
| Eastern Plaguelands | 1 | 1 | 1 |
| Mulgore | 1 | 0 | 1 |
| Desolace, Dire Maul, Icepoint Rock, Loch Modan, Stormwind Vault, Tel'Abim, The Farstrider Lodge, Uldaman, Winter Veil Vale, (none) | 1 each | 0 | 0 |
| Blackrock Spire, Cooking, Mirage Raceway | 0 | 1 each | 0 |

UNOFFERED without BROKEN: Reputation 30 (vanilla commendation officers, all spawns
`SPAWN_FLAG_DISABLED`), Karazhan 11, Un'Goro 5, Wetlands 4, Hunter 4, others 1-3.
EVENT_OFF: Lunar Festival 70, Seasonal 22, Invasion 10, Silithus 4, Tournament 1.

## The three owner cases

### 1. Karazhan: the teleport into the "second map" is missing (and a boss)

**Verdict: confirmed, and it is two separate gaps.** Upper Karazhan is map 814 ("Tower of
Karazhan"). It has two parts: the tower (Keeper Gnarlmoon, Ley-Watcher Incantagos, Anomalus,
King's council/chess, Echo of Medivh; x ≈ -11,100) and a second section far away on the same
map, `game_tele 934 "karaoutland"` at (-6078.9, -2395.5, 49.3), where Sanv Tas'dal (59981),
Kruul (59991) and Rupturan the Broken (59961) are spawned (x -6,248 … -7,190).

- **No player path into the second section.** Two areatriggers next to Echo of Medivh, 5349
  (-11168, -1636, 278) and 5350 (-11233, -1688, 290), exist in `areatrigger_template` for map 814
  but have no `areatrigger_teleport` row and no `scripted_areatrigger`. No script command 6,
  no `spell_target_position` and no C++ `TeleportTo` targets map 814. The areatrigger 5351
  (-11111, -1838, 231) near the chess room is dead too. Only a GM can get there.
- **The final boss is missing.** Mephistroth (93333, rank 3, level 63, 21 distinct loot items) has no
  spawn, no summon and no AI (`ai_name = EventAI` with 0 `creature_ai_events`). His loot is the
  only source of *Heart of Mephistroth* (41577 "Sovereign of Desolation"), *Soul of the
  Dreadlord* (41394) and the tier tokens *Nathrezim Armor of Treachery/Deceit* for 9 turn-in
  quests (41580-41628, Deadwind Pass): all BROKEN.
- Rupturan the Broken is spawned but has no abilities at all (no script, no EventAI, no spell
  list). Map 814 has no instance script (`map_template.script_name` empty), so there is no boss
  state or door logic.
- **The entrance itself: verify live.** `areatrigger_teleport 5340` "Tower of Karazhan - Entrance"
  → map 814 exists and requires the *Upper Karazhan Tower Key* (61234, condition 4163603). The
  key chain "The Key to Karazhan I-X" is complete in the data (credits in
  `random_scripts_3.cpp`, key from 40829). But `areatrigger_template 5340` says `map_id = 0`,
  while `game_tele 859 "entrancekara40"` puts exactly that spot (-11039.6, -1997.7, 94.1) on
  **map 532 (Lower Karazhan Halls)**. The spot is inside the Karazhan building, which on the
  continent is closed. The core drops an areatrigger when the player's map differs from
  `map_id` (`src/game/Database/DBCStores.cpp:616`, `IsPointInAreaTriggerZone`), logging
  "too far, ignore Area Trigger ID: 5340" at debug level. If the client's AreaTrigger.dbc
  has 5340 on map 532, keyed players can never enter from LKH. OB-20: stand on
  `.tele entrancekara40` with the key and check the debug log.

**Fix proposal:** (a) `areatrigger_teleport` rows for 5349/5350 → the "karaoutland" section
(target from `game_tele 934`), probably gated on Echo of Medivh being dead, which needs an
instance script for 814; (b) if the live check confirms it, correct `areatrigger_template
5340.map_id` to 532; (c) Mephistroth: a spawn in the Outland section and an encounter (Turtle
never published it; owner design like the #348 void lord); (d) abilities for Rupturan.
Effort: (a)+(b) S, instance script M, Mephistroth L.

### 2. Blackwing Lair "alchemy lab": the boss is not there

**Verdict: confirmed.** The boss is **Ezzel Darkbrewer** (65148, "Renowned Alchemist", rank 3,
level 63, faction 103 like the BWL dragonkin). He has a 26-row loot table (raid loot 33073-33097
plus the quest item *Transmutation Alloy* 42311), but:

- 0 spawns anywhere, no summon in any DB script, spell or C++ file;
- `ai_name = EventAI` with 0 `creature_ai_events`, no script, no spell list; his adds
  *Shadowflame Spark* (65151) and *Creeping Expulsion* (65152) are the same (0 spawns, 0 events);
- no Turtle object or trigger in BWL (map 469) points to a lab. The only non-vanilla objects
  there are the chest *Treatise on Magical Locks and Keys* (2011049, drops 61233 for "The Key
  to Karazhan IX") and a marker GO *Fel Orc Encampment Custom Area* (200000), both at
  (-7591, -1259, 481).

The pre-quest chain is the rogue class chain "A Key of Ancient Times" (42029-42036). 42031
"Elementium Lock" needs the Alloy from Ezzel, so it and its follow-ups are BROKEN. The chain
has more holes: 42030 needs *Dregheap's Information* from pickpocketing Ebenezer Dragheap (63185,
not spawned); 42032 needs a drop from Crimson Friar Freidhelm (63186, not spawned); 42034 ends at
Argur Rustbrand (63188, not spawned); 42036 needs *Runed Elementium Key* 42318 (no source) and
ends at GO 2020340 *Ancient Elven Chest* (not spawned). The rogue chain dead-ends at step 2
for anyone without GM help.

**Fix proposal:** place Ezzel and his adds (owner picks the lab spot; the marker at
(-7591, -1259, 481) is a candidate to check in the client), give him an encounter (EventAI or
creature_spells), then close the other rogue-chain holes (four NPCs, one GO, one item source).
Effort: L for the boss, M for the rest of the chain.

### 3. "Fullbore" = furbolg: fire bowls, Ursoc's portal, the boss

**Verdict: confirmed, with a name mix-up.** The quest line is the Timbermaw Hold raid (map 819,
reached through the *Maw of Ursoc* in Azshara, `areatrigger_teleport 5613`), quest giver Narkogg
the Dark (62740): 41930 → 41931 → 41932 → 41933 → 41934 "What Remains": *Slay Ursol*. The boss is
**Ursol** (62947). Ursoc (61546) is an RP NPC that `generic_scripts 4139602` summons in
the Moonglade chain "Into the Dream"; nobody kills him.

- The fire bowls are four braziers in Timbermaw Hold: 300602 Corruption, 300603 Defilement, 300604
  Decay, 300605 Putrification. Type 2 (questgiver), lock 1666, flags 32, `script_name = '0'`.
- The official item is *Essence of Purification* (42234, reward of 41933 and 42021). It casts
  34764 "Dowses a brazier in Timbermaw Hold" = effect 59 `OPEN_LOCK_ITEM` on a gameobject.
  That opens the lock, and then **nothing happens**: the braziers have no `gameobject_scripts`,
  no quest relation, no event id, map 819 has no instance script, and no C++ references
  300602-300606 or 62947.
- The "portal" is *Barrier of Ursol* (300606): a door (type 0) with `data0 = startOpen = 1`,
  flags 48 (NO_INTERACT | NODESPAWN), spawned with state 1. Nothing ever changes its state.
  `startOpen = 1` inverts the state meaning on the client (ready = open, active = closed), which
  may be why setting the GO state by GM "did nothing": the value that looks like "open" is the
  closed one. **Verify live.**
- **Even with the barrier open there is no boss:** Ursol has 0 spawns, 0 summons and 0
  `creature_ai_events` (15 distinct loot items, including the item for 42022 "Hide of a Wild God" via
  skinning, and loot for 42025).
- The rest of the raid has the same shape: all 282 creature spawns in map 819 (28 templates,
  among them the spawned bosses Ormanos, Rotgrowl, Archdruid Kronn, Chieftain Partath and Trioch)
  have `ai_name = EventAI` and **zero events**, so they have no scripted abilities (only
  Loktanag has one spell, via `spell_id1`). Nemasra (63014), Grammon the
  Ageless (63015, #370) and High Speaker Jam'wahli (63100) are not spawned, so 41932 and 41960
  are BROKEN too; Leni (63101) and Fangorn (63102) are missing for 41961/41962/41964.

**Fix proposal:** an instance script for 819 (or `gameobject_scripts` + a map event) that counts
the four doused braziers and then opens 300606 (`SCRIPT_COMMAND_OPEN_DOOR`); a spawn and
encounter for Ursol behind the barrier; spawns for Nemasra, Grammon, Jam'wahli; then EventAI for
the raid. Effort: brazier/door M, Ursol L, the raid's AI L.

## Other findings with high player value

1. **Alterac Valley turn-ins lost by a migration (REGRESSION).** `battleground_template` AV has
   `player_loot_id = 1`. In `sql/base`, `reference_loot_template` entry 1 has 16 rows with the
   8 player-corpse trophies (Severed Night Elf Head, Tuft of Gnome Hair, … Orc Tooth). Upstream
   migration `world/20260511053220_world.sql` ("a_rebuild_tables") drops and rebuilds the loot
   tables and does not bring entry 1 back. 16 AV quests (7361-7366, 7401-7402, 7421-7428) are
   BROKEN. Fix: re-insert the 16 rows from `sql/base` (S). The same rebuild left 72 items that had
   a loot source in `sql/base` with none; only these 8 are quest items.
2. **Scarlet Citadel (map 45, raid) has no entrance.** No `areatrigger_teleport` targets map 45.
   The only entrance is the portal GO 112920, whose `script_name = custom_dungeon_portal` is not
   registered by any C++ script (13 portal GOs use it; the other maps also have an areatrigger,
   Scarlet Citadel does not). S to M.
3. **Boss spawn gaps outside the three cases:** Echo of Sargeras (60063) and Corrupted Ashbringer
   (60064) for 41637 (Northwind); Spirit of Eskhandar (62112) for 41547; Grand Crusader Dathrohan
   (2000092) for 20002; Rholgast (62065) for 41393. Never-spawned bosses without a quest (loot
   only): Broodcommander Axelus, Dark Reaver of Karazhan, Concavius, and nine copies of world
   bosses (63107-63115) that the #348 migration now uses for summons (63107 Azuregos).
4. **Turtle quest credit triggers nobody gives.** Many Turtle quests use kill credit on
   invisible `quest_<id>_dummy_triger` creatures. Most are given by C++ (e.g.
   `random_scripts_3.cpp`, `custom_exploration_triggers.cpp`); those are OK_SUSPICIOUS. 13 quests
   have no source at all: Balor 41694 (blocks 8 follow-ups) and 41698, Grim Reaches 41731/41803
   (6 follow-ups), Moonwhisper Coast 41970/42068/42073 (6), Timbermaw 41956 (9)/41962,
   Winterspring 41649, Duskwood 41745, Northwind 41677/41682 (C++ only checks the reward status
   of a quest 60070, it never gives credit 60070).
5. **Quests without an ender:** 41947, 41948, 41950, 42012, 42050 (Moonwhisper Coast), 40749
   (Tel'Abim, also `NextQuestInChain = 40750` which does not exist).
6. **Missing completion scripts (#348), current state:** of the 34 listed there, 41935, 41936 and
   41966 now have rows (migration `20260926170000_world.sql`); 41913 and 41922 have no giver.
   13 are PARTIAL (the quest completes, the effect is lost), 7 are BROKEN for other reasons as
   well (items or enders missing: 41520, 41529, 41544, 41547, 41807, 41929, 41963), 5 are
   UNOFFERED (the 4 "Stone of Dreams" GOs and the giver of 41940 are not spawned), and
   5525/7429/6661/40348 are handled in C++ (dangling DB pointer only).
7. **Script names no C++ registers (SCRIPT_GAP, 33 names):** the NPCs run without their script.
   Spawned examples: `custom_dungeon_portal` (13 GOs), `npc_kitten`, `npc_nasuna`,
   `npc_teslinah`, `npc_breanna_darrowmont`, `npc_chieftain_icepaw`, several AQ war NPCs,
   `go_urok_challenge` (the UBRS Urok event), `go_warlock_demon_gate`, `spell_druid_wrath`
   (8 spells), `event_banner_destroyed`. Four `AddSC_*` functions exist but are never called:
   `boss_headless_horseman`, `boss_order_of_silver_hand` (Stratholme), `npc_sandstalker`,
   `instance_stormwind_vault` (the loader calls `..._vaults`, a different file).
8. **Instances without an instance script:** Tower of Karazhan (814) and Timbermaw Hold (819)
   (raids, SCRIPT_GAP); dungeons Stormwind Stockade, Ragefire Chasm, Hateforge Quarry, Windhorn
   Canyon, Frostmane Hollow (OK_SUSPICIOUS).
9. **Spawns removed by migrations (REGRESSION, deliberate per migration name):**
   `world/20260901174017` "remove_deprecated_npcs" removes the postworkers (61611/61612, 4 quests
   UNOFFERED), glyph masters and others; `world/20260829172251` removes Gowlfang (91243, 4 quests
   "Reunite Tribe-Tribe!" UNOFFERED). Owner decision whether those quests go too.
10. **Disabled content by design:** 107 EVENT_OFF quests (disabled events) and 30 commendation
    signet quests (officers disabled). Not bugs; listed so nobody chases them.

## Prioritisation proposal

1. **Raid and dungeon access**
   1. AV trophy loot (16 quests, S, restore from `sql/base`).
   2. Tower of Karazhan: entrance map check (live) and teleport to the Outland section (S), then
      the instance script (M) and Mephistroth (L). Unblocks 11+ quests and the tier turn-ins.
   3. Timbermaw Hold: brazier → barrier logic (M), Ursol, Nemasra, Grammon, Jam'wahli spawns
      and encounters (L). Unblocks the Narkogg chain (41932-41934, 42022, 42025) and 41960+.
   4. Scarlet Citadel entrance (S-M).
   5. BWL: Ezzel Darkbrewer (L).
2. **Chains with many follow-ups** (column `blocked_follow_ups`): 41087 Scythe of the Goddess
   (12), 80201 Stocking Up on Wood (12), 41956 Not Alone (9), 41694 To The Darkest Places (8),
   41803 The Skardyn (6), 42073 Facing the Elder (6), 42030 rogue chain (6), 41960 (5), 41932 (4).
   Most need one spawn or one credit source (S-M each).
3. **Single quests:** the remaining BROKEN rows, then PARTIAL (lost completion effects), then
   decide per UNOFFERED group whether to spawn the giver or retire the quest.

## Method and limits

Per quest the script checks: giver and ender (creature/GO questrelation, starting item) and
whether each is spawned, summoned by a DB script or spell, or referenced from C++; every
`ReqCreatureOrGOId` (spawn, summon, script kill credit, `quest_cast_objective` credit
`questId + idx*10`, C++); every `ReqItemId` (creature/GO/reference/item/pickpocket/skinning/
fishing/mail loot on an owner that is itself reachable, vendors, quest rewards and source items,
create-item spells that something can cast, script command 17); `ReqSpellCast`; explore/event
quests (`SpecialFlags & 2`: areatrigger relation, script command 7/83, QUEST_COMPLETE spells,
C++); `StartScript`/`CompleteScript` rows; `PrevQuestId`/`NextQuestId`/`NextQuestInChain`.
Core rules taken into account: `Method = 1` disables a quest, `Method = 0` skips creature/GO
objectives, `SPAWN_FLAG_DISABLED` spawns only load through script command 82/91, and spawns of
disabled `game_event`s do not appear.

Limits:

- **C++ references are pattern matches.** A literal on a line that looks like a quest, NPC or
  item constant counts as "handled in C++" and gives OK_SUSPICIOUS, not OK. Some are wrong
  (four were found and excluded by hand, see `FALSE_CPP_MATCH` in the script). 8 rows say
  "weak match, verify".
- **No client data.** Lock ids, AreaTrigger.dbc and model placement cannot be checked
  statically; those points are marked **verify live**.
- **Spawn does not mean reachable.** A spawned boss in an instance nobody can enter still
  counts as spawned.
- Quests with no giver at all (147) are not reported unless a live quest chains into them.
- Some names are double-encoded UTF-8 in the world data itself (e.g. `Jamâ€™wahli`); the CSV
  keeps them as stored.
- Top-level `sql/database_updates/*.sql` are not applied by the auto-updater
  (`sql/README.md`); they were included because the project applies them by hand.

## CSV columns

`quest_id, title, level, zone, category, cause, evidence, effort, verdict, blocked_follow_ups`.
One row per finding; a quest can have several rows. Content findings have an empty `quest_id`
and name the object in `title`. `evidence` is the query or data that shows the gap.
`effort` is a rough S/M/L. `verdict` is the verdict of the quest the row belongs to (see
Summary); `VERIFY_LIVE` and `MISSING_CONTENT` appear on content rows only.
`blocked_follow_ups` counts the quests after this one in its chain (via `PrevQuestId`,
`NextQuestId`, `NextQuestInChain`).
