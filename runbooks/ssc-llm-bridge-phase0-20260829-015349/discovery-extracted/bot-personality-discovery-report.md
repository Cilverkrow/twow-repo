# Bot Personality Discovery

This is a sanitized, read-only source and database inventory for a future Bot Personality and external LLM bridge. No personality table was created and no trait was assigned.

## Identity and inspection boundary

- Source: branch `playerbots-integration-gh`, commit `42b8a7f742548793910fe8880463aeeb71627fb9` (2026-08-25T15:22:11+01:00, dc: load recorded routes at runtime, and raise the instance gate).
- Database: `tw_char` on MariaDB `11.4.10-MariaDB`; reviewed owned PID `12408`.
- Worldserver binary: `C:\TW\ComTW\server\mangosd.exe` / `FB722BAAD894F2567A1535EF7A64AD9AEB31BCEA833012D9EC96DE53285E45FC`. It was not started.
- SQL: 15 statements, all SELECT/SHOW, zero write-capable statements, zero logical database writes.
- Expected MariaDB engine-runtime changes were isolated to 3 paths and are listed separately.

## Proven populations

| Population | Exact count | Meaning |
|---|---:|---|
| `random_account_stock` | 4500 | characters joined to tw_logon.account where the case-insensitive username begins with the configured RNDBOT prefix |
| `active_random_rotation` | 100 | distinct existing character GUIDs referenced by owner=0,event=add rows |
| `inactive_random_reserve` | 4400 | RNDBOT-prefix characters without an owner=0,event=add row |
| `configured_player_owned_always_online` | 0 | non-RNDBOT characters with owner=0,event=always,value=1 |
| `currently_active_runtime_bots` | 0 | No mangosd process existed during the capture. |
| `system_placeholder_event_rows` | 1 | ai_playerbot_random_bots rows with bot=0 |

The configured random-bot target is 50, but the database has 4,500 RNDBOT stock characters, 100 add-marked rotation characters, and 4,400 inactive reserve characters. This is not approximately 50 when measuring stock or add markers. Because mangosd was stopped, the authoritative currently running bot count is 0.
There is one non-random-account character. It is classified only as normal-or-unresolved non-bot stock; no character identity is exported. There are no ACTIVE always-online player-owned bot rows.
The single bot=0 row is a system placeholder and is never exported as a character GUID. Orphan event references: 0. Duplicate owner/bot/event extra rows: 0.

## Races and classes

All 10 locally defined playable race IDs occur in the random account stock; no locally defined race ID is unused. Race 9 is Goblin and race 10 is High Elf according to the pinned ChrRaces.dbc and SharedDefines.h. The zero core defines no Blood Elf race ID.
All 9 locally defined class IDs occur in the stock. The live playercreateinfo table contains 59 race/class definitions, and every observed bot combination is present there.
Random stock includes 1088 High Elves and 928 Goblins. All combinations involving these locally custom races are Turtle-WoW-specific. RandomPlayerbotFactory.cpp also explicitly documents Human Hunter as a custom non-vanilla combination.

## Appearance and variants

The characters table persists gender, playerBytes, and playerBytes2. Player.cpp decodes playerBytes as skin, face, hair style, and hair color and the low byte of playerBytes2 as facial features. Race display models come from ChrRaces.dbc. No PlayerBot-specific display/model override column was found in the relevant character or PlayerBot tables.
CharSections.dbc contains 6617 records. Normalized bot appearance tuples with a face/hair/facial-feature combination not matched by the local CharSections rules: 0. This check validates local customization encoding; it does not prove a semantic visual race variant.
The world custom_character_skins table is token-driven and writes a skin byte. The persistent character row does not preserve the token provenance, so a Blood-Elf-looking or other cosmetic variant cannot be proven. Every exported race_variant_key is null.

## Professions and skills

character_skills(guid, skill, value, max) is the authoritative persisted character-skill table. SpellMgr classifies SkillLine category 11 as primary professions and additionally recognizes First Aid (129), Survival (142), Cooking (185), and Fishing (356). Riding is explicitly outside IsProfessionSkill.
Locally defined professions: 14. Learned profession rows across normalized proven bots: 0. Bot population-membership rows with no profession: 4500; one profession: 0; two or more: 0.
Unmapped observed skill IDs: 0. Duplicate population/GUID/skill records: 0. Every locally defined profession, including Turtle-WoW Survival, is unused by the proven bot populations in this capture.

## Unresolved findings

- No standalone Blood Elf race ID exists in the pinned zero-core SharedDefines.h or ChrRaces.dbc; race 10 is locally named High Elf.
- The custom_character_skins world table maps item tokens to skin-byte values, but the persistent characters row does not retain which token caused a skin value. A Blood-Elf-looking or other cosmetic variant therefore cannot be proven from the captured rows; race_variant_key remains null.
- One login marker exists, but the Worldserver was stopped and RandomPlayerbotMgr clears login markers during construction. It is not classified as a currently active bot.
- The database contains 100 add-marked rotation characters while MinRandomBots, MaxRandomBots, and the bot_count placeholder are 50. The source treats add rows as the rotation set; the reason for the stale or expanded set cannot be proven read-only.
- No learned primary, secondary, or custom Survival profession row exists for any normalized proven bot in character_skills.
- On-demand player-owned bots that have no ACTIVE always marker cannot be distinguished from normal player characters in an offline database capture.

## Validation

- Normalized exported bot rows: 4500; unique proven bot GUIDs: 4500.
- Every exported GUID came from an authoritative characters join and a proven normalized population; no GUID range was used.
- Race, class, and profession keys are one-to-one with locally verified numeric IDs.
- Profession lists are numerically sorted; JSON and TSV counts reconcile.
- No character identity, account identity, credential, authentication material, network address, personal contact data, or full database row is exported.
- MariaDB stopped cleanly; mangosd and realmd were never started; ports 3307 and 8090 were closed at completion.
- No trait assignment has occurred.
