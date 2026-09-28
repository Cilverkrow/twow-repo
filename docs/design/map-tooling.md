# Map, instance and dungeon tooling: formats, editors, extraction, pilot

Refs #412. Status: **design only (train 8, planning)**. This document changes no
code, config, DBC, SQL or client file. It adds no binaries and no Blizzard or
Turtle client data (ADT/WDT/WMO/M2/DBC/BLP).

**Inputs:**

- the cloud brief "Cloud-Auftrag (OB-00, 28.09.2026)"
  ([#412 issuecomment-5872907608](https://github.com/Cilverkrow/twow-repo/issues/412#issuecomment-5872907608))
  and the Noggit note in
  [#412 issuecomment-5859674702](https://github.com/Cilverkrow/twow-repo/issues/412#issuecomment-5859674702);
- the map 45 history in #408: the live loading-screen hang, OB-30's per-map check
  ([#408 issuecomment-5859567949](https://github.com/Cilverkrow/twow-repo/issues/408#issuecomment-5859567949)),
  the owner decision "ruhen lassen + absichern" and twow-core#198;
- the client patch design of PR #410, `docs/design/client-patch-pipeline.md`
  at `121a0b2` (revision 2). **This document builds on it and does not repeat
  it.** Wherever it says "the #410 pipeline", it means that document's sections
  2.2 (load order, `patch-X.mpq`), 3.1–3.4 (DBC ↔ SQL, `dbcdiff`, mpqcli, build
  steps 1–9), 5 (Nostalgia assets) and 6 (legal).

**Short answer to the owner's question:**

- **Custom maps are feasible, but only as a two-part release:**
  - client files (WDT, ADTs or a WMO reference, plus `Map.dbc` and friends) go
    through the #410 pipeline in `patch-X.mpq`;
  - server data (maps/vmaps/mmaps, `map_template`, spawns, entrance) is
    extracted from **the same patched client**.

  The server cannot send a map to the client. A map the client does not know
  hangs the loading screen. That happened with map 45 on 2026-09-27.
- **No editor writes real 1.12 terrain today.** Every maintained Noggit is
  3.3.5a-first. Noggit Red accepts only WotLK and Shadowlands projects. The only
  3.3.5 → 1.12 ADT downconverter found, warcraft-rs, loses liquids (section 2.4).
- **The cheap and safe pilot is path (a):** a WMO-only map that reuses an
  existing 1.12 WMO under a new map ID. It needs:
  - one small WDT, which we generate;
  - a few DBC rows, which we generate;
  - a new spawn layout for the existing Scarlet Citadel content.

  There is no terrain editing and no format conversion.
- **Two tooling gaps sit on our side:**
  - the extractors **do not read lettered patches** such as our `patch-X.mpq`
    (section 3.1);
  - nothing checks that every server map exists in the client (the Luigi
    incident in #408).

  Both are small, and we should fix them first (sections 6 and 7).
- **No second toolchain.** Following the owner's tool principle (#409), every
  map tool is generic (any map ID, any client version) and plugs into the
  #409/#410 client toolchain: DBC deltas and bindings, `dbcdiff`, the build
  manifest, the consistency check. Map work adds bindings, rules and a WDT
  generator, not a parallel pipeline (section 6.1).
- **Patch file name.** This document says `patch-X.mpq` as in #410. The name is
  still an open point in #409 (`X` vs `Z`), and nothing here depends on it.

## Contents

1. [Evidence base and confidence markers](#1-evidence-base-and-confidence-markers)
2. [Formats: what makes a map, 1.12 vs 3.3.5, converters](#2-formats-what-makes-a-map-112-vs-335-converters)
3. [Server side: extractors, a new map ID, bots](#3-server-side-extractors-a-new-map-id-bots)
4. [Editors and tools](#4-editors-and-tools)
5. [Pilot: path comparison](#5-pilot-path-comparison)
6. [Tools we could build](#6-tools-we-could-build)
7. [Staged plan with acceptance checks](#7-staged-plan-with-acceptance-checks)
8. [Open owner decisions](#8-open-owner-decisions)
9. [Sources](#9-sources)

## 1. Evidence base and confidence markers

| Marker | Meaning |
|---|---|
| **[code]** | Read from `Cilverkrow/twow-core` `main` = `15fc5da`, with file and line. twow-repo's core pin is `6a5ad6d`; `tools/`, `src/game/Maps`, `ObjectMgr.cpp` and `World.cpp` do not differ between the two. twow-repo read at `main` = `90834ea`. |
| **[tool]** | Read from the tool's own repository, cloned read-only into the session scratchpad. Commit and licence file are given in section 9. |
| **[dbd]** | DBC layouts from `wowdev/WoWDBDefs` @ `e989e99` (2026-09-25), build `1.12.1.5875` vs `3.3.5.12340`. |
| **[#408]** | Measured by OB-30/OB-00 on the owner's host and clients. |
| **[community]** | Search excerpts only. wowdev.wiki, the Turtle forum and wowmodding.net are blocked by the session's egress proxy, so these are **not verified against the page text**. |
| **[speculation]** | Reasoned, not sourced. Each one has a test in section 7. |

The cloud session had **no access to any client**. Nothing here comes from reading
client files.

## 2. Formats: what makes a map, 1.12 vs 3.3.5, converters

### 2.1 The files of a map

| File | What it is | Terrain map | WMO-only map (most dungeons) |
|---|---|---|---|
| `World\Maps\<Dir>\<Dir>.wdt` | Tile grid (`MAIN`, 64×64), header flags (`MPHD`), for WMO-only maps the one global WMO (`MWMO` + `MODF`) | yes | **yes, the whole map** |
| `World\Maps\<Dir>\<Dir>_<x>_<y>.adt` | One terrain tile: heights, normals, texture layers and alpha maps, shadows, liquids, doodad/WMO placements | yes | no |
| `<Dir>.wdl` | Low-resolution far terrain | yes | optional |
| `*.wmo` + `*_NNN.wmo` | Building/dungeon geometry: root + groups (format v17 in both versions) | placed by ADTs | the dungeon itself |
| `*.m2` (+ `.skin` in 3.3.5) | Doodads and creatures | yes | yes |
| `*.blp` | Textures, minimap tiles (`Textures\Minimap\*`, via `md5translate.trs`) | yes | yes |
| `DBFilesClient\Map.dbc` | **The map exists at all**: directory, instance type, loading screen | **required** | **required** |
| `AreaTable.dbc` | Zone/subzone names, flags, exploration | recommended | recommended |
| `WMOAreaTable.dbc` | Names/flags per WMO group (indoor subzones) | – | recommended |
| `LoadingScreens.dbc` | Loading screen image | reuse an ID | reuse an ID |
| `WorldMapArea.dbc` (+ overlays) | World map (M key) | optional | optional |
| `AreaTrigger.dbc` | **Client-side trigger volumes.** The client only reports a trigger it has in this DBC [community]. | only for trigger entrances | only for trigger entrances |

The server loads **none** of `Map.dbc`, `AreaTrigger.dbc` or `LoadingScreens.dbc`
[code]:

- maps come from `map_template` (`ObjectMgr.cpp:4929-4990`);
- `MapEntryfmt` exists in `DBCfmt.h:51` but is never used;
- triggers come from `areatrigger_template`/`areatrigger_teleport`.

The #410 table in its section 2.3 already records this. The consequence here:
**client and server map lists can drift apart unnoticed.** That is exactly how
map 45 happened [#408]:

- 23 spawns, 11 bosses and `instance_scarlet_citadel` exist server-side;
- no client (2025 or 2026) has `Map.dbc` 45 or any WDT/ADT for it.

### 2.2 DBC layouts, 1.12.1 vs 3.3.5a [dbd]

| DBC | 1.12.1 fields | 3.3.5a fields | Differences that matter |
|---|---|---|---|
| `Map` | 18 | 17 | 1.12 has `MapType`, `MinLevel`, `MaxLevel`, `MaxPlayers`, `ParentMapID`, `Continentname`. 3.3.5 replaces these with `Flags`, `PVP`, `AreaTableID`, `CorpseMapID`, `Corpse[2]`, `TimeOfDayOverride`, `ExpansionID`. **Not row-compatible**, so a 3.3.5 editor's Map.dbc output cannot be copied. |
| `AreaTable` | 14 | 17 | 3.3.5 adds `MinElevation`, `Ambient_multiplier`, `LightID` |
| `LoadingScreens` | 3 | 4 | 3.3.5 adds `HasWideScreen` |
| `WorldMapArea` | 8 | 11 | 3.3.5 adds `DisplayMapID`, `DefaultDungeonFloor`, `ParentWorldMapID` |
| `AreaTrigger` | 8 | 8 | same layout |

**Caveat [speculation]:** the Turtle 1.18.1 client (build 7272) may carry
extended layouts. The #410 pipeline's step (1) extracts the real base files, and
`dbcdiff` round-trips them. **Our own row generator must verify the field count
against the base file** before writing, and must not trust WoWDBDefs alone.

### 2.3 ADT, WDT, WMO, M2: 1.12 vs 3.3.5

The ADT chunk versions are the same in both (`MVER` = 18). The changes come as
optional chunks and header flags:

| Area | 1.12 | 3.3.5a | Source |
|---|---|---|---|
| Liquids | **`MCLQ`** inside each `MCNK` | **`MH2O`** at tile level (referenced from `MHDR`) | [tool] noggit3 `MapTile.cpp`/`MapChunk.cpp`, warcraft-rs `converter.rs` |
| Flight bounds | – | `MFBO` (TBC+) | [tool] warcraft-rs strips it for Classic |
| Texture flags | – | `MTXF` (WotLK) | [tool] noggit3 `MapHeaders.h:68-70` |
| Vertex colours | `MCCV` rare | common; WDT `MPHD` 0x2 | [tool] warcraft-rs `wdt.md` |
| Alpha maps | 2048-byte 4-bit (`MCAL`) | **"big alpha"** 4096-byte 8-bit, WDT `MPHD` 0x4 (≈60 % of 3.3.5 maps) | [tool] warcraft-rs `wdt.md` flags, "Evolution Across Versions" |
| WMO-only map | WDT `MPHD` 0x1 + `MWMO` + `MODF` | same | [tool] warcraft-rs `wdt.md` |
| WMO | v17 | v17; group flags, vertex colours, liquid (`MLIQ`) and shader details differ | [tool] WBS `wmo_scene_group.py:117` (legacy liquid for vanilla/BC) |
| M2 | version **256**, skins embedded | version **264**, external `.skin` | [tool] warcraft-rs `convert-testing-results.md` (DwarfMale 256 → 264) |
| Textures | BLP1 | BLP2 | [tool] warcraft-rs `blp convert` |

**The practical meaning:**

- A 1.12 client **cannot** read 3.3.5 water (`MH2O`).
- A 1.12 client **probably** ignores the unknown chunks `MFBO`/`MTXF` and the
  extra `MHDR` offsets [community: "WOTLK ADTs will work in vanilla, except …
  water"; unverified].
- **Big alpha is the unknown.** If an ADT is written with 4096-byte alpha maps,
  the 1.12 client reads them as 2048-byte maps, and the textures will be garbled
  [speculation]. Test C1 in section 7 settles it.

### 2.4 Converters (downward: 3.3.5 → 1.12)

| Tool | Direction / scope | State | Licence |
|---|---|---|---|
| **wowdev/noggit3** "Use MCLQ Liquids (vanilla/BC) export" | Writes a **second copy of each saved ADT with MCLQ liquids** into a separate folder (commit `2893aadc`, 2024-05-24, "noggit: implement option to save liquids as MCLQ"). In that mode it also clears `do_not_fix_alpha_map` (`MapChunk.cpp:1638`). It still writes `MFBO`/`MTXF`. | The closest thing to a 1.12 terrain export. It is **not advertised as vanilla support** ("a wow map editor for 3.3.5a", `ui/About.cpp:30`). | GPL-3.0 |
| **Noggit Red** | Same MCLQ export option (`SettingsPanel.ui:859`) | as above | GPL-3.0 |
| **warcraft-rs** `adt convert --to classic` (`wow-adt`) | Chain WotLK → TBC → Classic | **Not usable for water:** `wotlk_to_tbc` sets `liquid_offset = 1; // Placeholder` and drops `MH2O` (`converter.rs:250-276` @ `76bedfd`). Its own test report lists only TBC → Classic as verified; WMO **group** conversion is "pending". | MIT or Apache-2.0 |
| warcraft-rs `wdt convert` | Classic/TBC/WotLK/MoP | "Working" per its test report (2026-01-11) | MIT or Apache-2.0 |
| **jM2converter** (`WowDevs/jM2converter` @ `b9dcb83`, 2016) | M2 of any version → **Classic** (`-cl`, `Constants.java`) | CLI, Java; old but targeted. Its README warns that retro-porting loses newer features. | GPL-2.0 |
| warcraft-rs `m2 convert` | M2 256 ↔ 264 both ways, animations preserved (test report) | "Working" | MIT or Apache-2.0 |
| MultiConverter, wotlkconv, MapUpconverter | Legion/modern → 3.3.5, or 3.3.5 → modern | **wrong direction** for us | – |

**Result:** a clean, maintained **3.3.5 → 1.12 terrain converter does not
exist.** The realistic chain for new terrain is:

1. Noggit (3.3.5a project) with **big alpha off** and the **MCLQ export on**;
2. strip `MFBO`/`MTXF`, a few lines with warcraft-rs's chunk writer or our own;
3. verify in the 1.12 client.

That is research, not a product (path c).

## 3. Server side: extractors, a new map ID, bots

### 3.1 Extractors in twow-core [code]

All four are built only with `USE_EXTRACTORS=ON`. The option is off by default
(`CMakeLists.txt:107`) and off in CI (`ci.yml:407,422`). They read MPQs through
the bundled **libmpq**, not StormLib.

| Tool | Reads | Writes | Map list | Notes |
|---|---|---|---|---|
| `mapextractor` (`tools/extractor/`) | `dbc.MPQ, terrain.MPQ, patch.MPQ, patch-2 … patch-9.MPQ` (hard-coded, `System.cpp:101-114`, `1013-1022`) | `dbc/`, `maps/%03u%02u%02u.map` | **Map.dbc** (`:256-272`); a map without a WDT is skipped silently (`:940-944`) | `-i` in, `-o` out, `-e 1/2/3` maps/dbc/both |
| `vmapextractor` (`tools/vmap_extractor/`) | `terrain, model, texture, wmo, base, misc`, then `patch.MPQ`, `patch-2 … patch-99.MPQ` (`vmapexport.cpp:344-398`) | `Buildings/` | **Map.dbc**, fatal if missing (`:513-527`) | `-d` data path, `-l` large |
| `vmap_assembler` | `Buildings/` | `vmaps/%03u.vmtree`, `%03u_%02u_%02u.vmtile` | – | |
| `MoveMapGen` (`tools/mmap/`) | `./maps`, `./vmaps` | `mmaps/%03u.mmap`, `%03u%02i%02i.mmtile` | **directory listing**, not Map.dbc (`MapBuilder.cpp:61-111`) | `[mapId]` builds one map; `--tile x,y`; `--offMeshInput` (text); `--settingsInput` (CSV, one row for map 189). The **all-maps run skips 42 and 169** (`--skipJunkMaps`, default true, `MapBuilder.cpp:442-450`); an explicit `MoveMapGen 169` builds it (`generator.cpp:333-335`). |

**Findings that matter for custom maps:**

1. **Lettered patches are invisible to both extractors.** `mapextractor` stops
   at `patch-9`, and `vmapextractor` scans only numeric `patch-N`. Our
   `patch-X.mpq` (#410 section 2.2) would carry the new `Map.dbc` and WDT. As
   things stand, **neither extractor would see our map**, and both take their map
   list from Map.dbc. This needs fixing before any custom map (tool T1, section 6).
2. **MoveMapGen does not need Map.dbc.** Once `maps/`/`vmaps/` exist for an ID, it
   builds mmaps for it.
3. **Why map 169 has no mmaps [#408]:** the default all-maps run skips it as a
   "junk map". `MoveMapGen 169` alone is the fix, with no code change.
4. `tools/mmap/mmap_extract.py` is Python 2 with a stale map list. Its readme
   says "DEPRECATED, NOT ACTUAL FOR TURTLE".

**Container, reproducibly (twow-repo) [code]:**

- `deploy/compose/Dockerfile.tools` builds the four tools on `debian:trixie-slim`
  with `-DUSE_EXTRACTORS=ON -DMODULES=disabled` from the `core` submodule, so
  they share the server's pin.
- The compose service `extractor` (profile `tools`, `make extract`) mounts:
  - `CLIENT_PATH:/client:ro`;
  - `DATA_PATH:/out`.

  **The client is never baked into the image** (ADR-0023).
- `deploy/compose/extract-client-data.sh`:
  - symlinks `Data` from the read-only mount;
  - runs the chain;
  - **skips an output directory that is already non-empty**, so a partial
    regeneration needs an empty target.
- **Rule for our use:** always point `DATA_PATH` at a new `data-v<date>`
  directory, never at the live one. This matches OB-30's plan in #408: side by
  side, with a manifest and SHA256SUMS; rollback is the old mount.

### 3.2 What a new map ID or instance needs in the core [code]

| Piece | Where | Required? | Notes |
|---|---|---|---|
| `map_template` row | `entry, parent, map_type (0 world/1 dungeon/2 raid/3 bg), linked_zone, player_limit, reset_delay, …, map_name, script_name` (`sql/base/tw_world_map_template.sql`) | **yes** | `MapManager::CreateMap` returns null for an unknown ID (`MapManager.cpp:148-150`). A raid requires a raid group (`:211-230`). There is no separate `instance_template`. |
| Instance script | `map_template.script_name` → `Map::CreateInstanceData` (`Map.cpp:2014-2035`) | optional | Scarlet Citadel has one: `src/scripts/dungeons/scarlet_citadel/`, `AddSC_instance_scarlet_citadel` |
| Entrance: area trigger | `areatrigger_template` + `areatrigger_teleport` (`ObjectMgr.cpp:5200`, `5717-5768`) | one of these two | Rejected when the trigger has no template or the target map has no `map_template`. **Also needs a client `AreaTrigger.dbc` row** [community], so this is a coupled client release. |
| Entrance: portal GO | `gameobject_template.script_name` | one of these two | Server-only, no client DBC. The `custom_dungeon_portal` script used by 13 Turtle GOs **does not exist in `src/`** [#408]. |
| Terrain files | `DataDir/maps`, `vmaps`, `mmaps` | see below | |

**Missing data files do not crash the server** [code]:

- `GridMap::loadData` treats a missing `.map` as success ("Not return error if
  file not found", `GridMap.cpp:71-80`);
- vmap and mmap failures log at DEBUG;
- `PathFinder` falls back to a straight line (`PathFinder.cpp:106-109`);
- the only hard exit is for the six start areas on maps 0/1 (`World.cpp:1981-1991`).

**A map without data therefore runs silently wrong:** no ground height, no line of
sight, no paths. The validator (T2) must flag that, because the server will not.

**Map IDs above 999** would break the `%03u` file naming that MoveMapGen parses
by position [speculation from the formats above]. Keep custom IDs **below 1000**
(decision 8.2).

### 3.3 Bots and dungeon clearing [code]

- **Travel nodes (mod-playerbots):**
  - tables `ai_playerbot_travelnode`, `_link`, `_path`;
  - loaded by `TravelNodeMap::loadNodeStore` (`TravelNode.cpp:3448-3530`);
  - at startup: load, then `generateAll`, then save (`TravelMgr.cpp:1861-1869`).
    An **empty** table triggers a full generation; unlinked nodes trigger path
    generation.
  - Paths are built on **mmaps** (`buildPath`). Without mmaps they fall back to
    straight lines.
  - The shipped nodes cover classic maps only.
  - Moderator debug commands exist (`debug add node`, `gen node`, `gen path`,
    `save node`, `DebugAction.cpp:168-186`). There is no config key.
  - **Caution:** `saveNodeStore` deletes all rows and re-inserts them
    (`TravelNode.cpp:3343-3430`). Any node work runs on a copy of the table first.
- **mod-dungeon-clear:**
  - routing is live over the navmesh, so **mmaps are a hard requirement**;
  - bosses come from `data/dc_roster.txt` (`credit <entry>`,
    `order <mapId> <entry> <index>`, reloadable) or the compiled
    `DcBossEntries1121.h`;
  - recorded routes (`routes/Route_<map>_<boss>.route`) are optional;
  - `tools/gen_routes.py` only regenerates the collector file.
- **For a new instance:**
  1. mmaps;
  2. roster lines (boss entries and order);
  3. optional entrance and boss travel nodes, so that bots find their way *to*
     the instance;
  4. optional recorded routes.

## 4. Editors and tools

| Tool | 1.12 read | 1.12 write | Platform | Mode | Reproducible | Licence | Use for us |
|---|---|---|---|---|---|---|---|
| **wowdev/noggit3** @ `59e58ad` (2026-04-13) | partial (reads `MCLQ`, `MapChunk.cpp:199-205`) | terrain via MCLQ export only, see 2.4 | Windows/Linux (Qt5, CMake) | GUI, Lua 5.1 script brushes | no (manual) | GPL-3.0 | new terrain, experimental (path c) |
| **Noggit Red** (`gitlab.com/prophecy-rp/noggit-red` @ `b274edb`, 2026-09-21) | like noggit3 | like noggit3 | Windows first (Qt5, StormLib, CascLib) | GUI | no | GPL-3.0 | **Projects only for "Wrath Of The Lich King" or "Shadowlands"**: `ClientVersionFactory::mapToEnumVersion` asserts otherwise (`ApplicationProject.cpp:237-244`). The `VANILLA` enum value has no code path. Its map-creation wizard writes 3.3.5 `Map.dbc` rows (not 1.12, see 2.2). |
| tswow/noggit3 @ `29a1557` | – | – | – | – | – | GPL-3.0 | **archived**, merged into wowdev/noggit3 |
| azerothcore/noggit @ `19f408f` (2017) | – | – | – | – | – | GPL-3.0 | stale |
| Cryect's original Noggit (2007) | yes | yes | old Windows | GUI | no | unclear, no maintained source | **not recommended**: unmaintained since 2.0, no traceable source or licence [community] |
| **WoW Blender Studio** (`gitlab.com/skarnproject/blender-wow-studio` @ `8512169`, 2025-12-20) | via its WMO importer | **WotLK or Legion only** (`ui/panels.py:66-70`) | Blender (any OS) | GUI + Python | partly | GPL-3.0 | new or edited WMOs (then a 1.12 check); M2 through a converter |
| **WMVx** (`Frostshake/WMVx` @ `90a4d9e`, 2026-07-19) | yes: "Vanilla (1.12.1)" | – | Windows | GUI | – | GPL-3.0 | choosing models, displays and textures. The owner's `Y:\WMV` covers the same job |
| **jM2converter** @ `b9dcb83` | – | M2 → Classic (`-cl`) | Java | CLI | yes | GPL-2.0 | down-porting M2 doodads |
| **warcraft-rs** @ `76bedfd` (2026-07-09) | ADT/WDT/WMO/M2/BLP/DBC/MPQ | WDT, M2, BLP, MPQ build; ADT only without water | Linux/Windows (Rust) | CLI + library | **yes** | MIT or Apache-2.0 | container tooling: WDT generation, BLP conversion, validation, possibly MPQ packing |
| **WDBX Editor** (`WowDevTools/WDBXEditor` @ `d34cee1`, 2020) | DBC, definition "Classic 1.12.1 (5875)" | yes | Windows (.NET) | GUI | no | **no licence file** | manual inspection of `Map.dbc` and friends, never a build step |
| WoW-Spell-Editor, mpqcli/StormLib, Ladik's MPQ Editor | – | – | – | – | – | – | as decided in #410 (section 3); not repeated here |

**Licence consequences, as in #410 section 3.1:**

- We **use** GPL tools as programs. We do not vendor their code into our repos.
- warcraft-rs (MIT or Apache-2.0) is the only candidate we could **depend on as a
  library** in our own tools without licence friction.
- Tools without a licence file (WDBX Editor, WoW-Spell-Editor) are used
  **locally as published binaries only**.

## 5. Pilot: path comparison

**The content:** the Scarlet Citadel content already in the DB:

- 23+ creature spawns, 12 GOs and 11 rank-3 bosses on map 45;
- `instance_scarlet_citadel` (C++);
- its loot.

Per the owner decision in #408 it rests, secured by twow-core#198.

**Important [#408]:** the spawn **coordinates** were made for Turtle's
unreleased geometry, which no client has. Every path therefore needs a **new
spawn layout**. What we reuse are the templates, loot, AI and script, not the
positions.

### (a) Reuse existing geometry under a new map ID (recommended)

- **Client** (all generated by us, shipped through the #410 pipeline in
  `patch-X.mpq`):
  - a WMO-only WDT (`MPHD` 0x1, `MWMO` = the path of an **existing** 1.12 dungeon
    WMO, `MODF` placement);
  - a `Map.dbc` row;
  - optionally an `AreaTable` and `WMOAreaTable` row for the name;
  - the `LoadingScreens` ID reused.

  **No ADT, no new model, no Blizzard file copied.** The WDT is a few hundred
  bytes built from a text spec in Git (tool T4).
- **Server:**
  - extract vmaps/mmaps from the patched client (this needs T1);
  - `map_template` for the new ID (or reuse row 45, decision 8.3);
  - new spawn coordinates;
  - the portal-GO entrance (server-only) instead of a trigger;
  - dungeon-clear roster lines.
- **Candidate WMOs:** a Scarlet Monastery wing (map 189 is WMO-only,
  lore-matching), or the old `Monastery` WDT that OB-30 found in the 2025 client
  as map 44 (WDT only, 0 ADT). Both are existing client files, so the client
  already has every model and texture.
- **Effort: S–M.** A DBC row generator, a WDT generator, the extractor fix, one
  migration for the spawns, and a live test. The biggest item is placing about
  30 spawns by hand in-game (`.gps`), which is content work (OB-20).
- **Risk: low.** The known format, the known engine path (the same as
  retail's WMO-only instances) and a fail-closed fallback (without the patch, no
  entrance is offered).
- **Limitation:** the geometry is familiar (a "remix"), not a new place.

### (b) Use Turtle's map 45 data server-side

- **Not possible.** OB-30 checked both the 2025 and the 2026 client: **no
  `Map.dbc` 45 and no WDT/ADT anywhere** [#408]. There is nothing to extract or
  distribute.
- The server content (templates, script, loot) is reusable and already ours in
  the DB. It is the input to (a) or (c), not a path of its own.
- **Legal:** the brief allows (b) only if it is clean. Obtaining Turtle's
  unreleased map files from any other source (leaks) is **excluded** (#410
  section 6: "No search for or use of leaked Turtle sources").

### (c) New terrain with Noggit, converted to 1.12

- **Client:**
  - Noggit (3.3.5a project) with big alpha off, the MCLQ export, and
    MFBO/MTXF stripped;
  - `Map.dbc`, `AreaTable`, `WorldMapArea`, the `WDL`, minimap BLPs and
    `md5translate.trs` entries;
  - probably new WMOs made in WBS (WotLK output, then a 1.12 check);
  - M2 doodads through jM2converter `-cl`.
- **Server:** the full extraction (maps + vmaps + mmaps), travel nodes, spawns.
- **Effort: L–XL.** Tooling research (tests C1–C3), then level design, which is
  the real cost: weeks of manual work per zone.
- **Risk: high.**
  - unverified format behaviour (big alpha, water, WMO shader details);
  - no maintained 1.12 editor;
  - every client crash needs a round trip through the #410 pipeline.
- **Distribution:** the same `patch-X.mpq`, but far larger (textures, minimap).
  The asset size affects Nostalgia downloads over Radmin.

### Comparison

| | (a) reuse WMO | (b) Turtle map 45 | (c) new terrain |
|---|---|---|---|
| Client files | WDT (ours, generated) + DBC rows | none exist | ADT/WDT/WDL/BLP/DBC (+ WMO/M2) |
| New formats to master | none | – | ADT downconversion, WMO/M2 1.12 checks |
| Tools we must build | T1–T4 (T5–T8 recommended) | – | T1–T4, T9 + converter glue |
| Content effort | new spawn layout | – | level design + spawns |
| Patch size | kilobytes | – | tens to hundreds of MB |
| Effort | **S–M** | not possible | **L–XL** |
| Risk | **low** | – | high |
| Recommendation | **pilot** | drop as a path; reuse its DB content | later, after C1–C3, only if (a) proves the pipeline |

## 6. Tools we could build

### 6.1 Ground rules: the owner's tool principle and one shared toolchain

Two rules bind every tool below:

- **The owner's tool principle**
  ([#409 issuecomment-5874344129](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5874344129),
  2026-09-28), binding for #412. Each tool must be:
  1. general rather than built for one case;
  2. data-driven and repeatable;
  3. tested (synthetic data, a round trip, a consistency check against server
     SQL);
  4. documented in a README;
  5. maintainable across client versions (base fingerprint, pinned versions,
     a clear error on an unknown base);
  6. usable locally and in the cloud.
- **One toolchain, not two.** #409 stage 1 is building the client toolchain as
  the owner commissioned it
  ([#409 issuecomment-5874183685](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5874183685),
  plan in
  [issuecomment-5874199786](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5874199786)).
  It consists of:
  - a CSV/YAML **delta format per DBC** with bindings;
  - a WDBC reader/writer;
  - `dbcdiff` → `review.csv`;
  - a build script (deltas → DBC → MPQ, version + sha256);
  - a **consistency check against server SQL** that already includes
    `map_template`/`areatrigger_template`.

  Its location is `ops/clientpatch/` (proposed; the `tools/` vs `ops/`
  decision is open in #409).

**Map tooling therefore adds bindings, checks and generators *to* that
toolchain, and builds no parallel one.** Map work is simply another DBC delta
set, plus two non-DBC outputs (a WDT, server data).

### 6.2 The tools

"Generic" in the table says how each tool avoids being a map-45 special case.

| ID | Tool | Where | Generic because | Benefit | Effort | Order |
|---|---|---|---|---|---|---|
| **T1** | **Extractor archive option**: `mapextractor` and `vmapextractor` take the full client load order, i.e. `patch-A … patch-Z` after `patch-9`, or an explicit archive list. Plus `extract-client-data.sh` options for a **map-ID subset** and a **fresh output directory**. | twow-core (C++) + twow-repo (script) | Works for any archive name and any map ID. The archive list comes from the same load-order definition the #409 build uses. An unknown or missing archive is a clear error, not a silent skip. | Without it **no custom map can be extracted**. It also closes a latent Turtle risk (content in lettered patches). | S (~50 lines per tool + a contract test that pins the archive order) | 1 |
| **T2** | **Map consistency rules** in the #409 consistency check. For **every** map ID: client `Map.dbc` (the base plus our deltas) vs `map_template`; spawns (`creature`/`gameobject`); `game_tele`; `areatrigger_teleport` targets; portal-GO targets; and the `DataDir` files (`maps`/`vmaps`/`mmaps`). Status per ID: ok / client-missing / data-missing / unreachable / unreleased. | #409 toolchain | Rules over all maps, no ID list in code. The same run checks today's Turtle maps and every future one. | Prevents the next map-45 hang, and is the acceptance check of every stage below. | S (rules on top of #409's check) | 1 |
| **T3** | **Map DBC bindings and a "new map" delta template** for `Map`, `AreaTable`, `WMOAreaTable`, `LoadingScreens`, `AreaTrigger`, `WorldMapArea`: bindings per client version (1.12 layouts from 2.2, field count verified against the base file); a documented template "add a map" = one delta file per DBC. | #409 toolchain (bindings + example deltas) | Any number of maps, any ID from the reserved block (decision 8.2); a new client version is a new binding file. | Custom maps need no hand-edited DBCs, and each map is a reviewable delta in Git. | S | 2 |
| **T4** | **WDT generator** as a build step: a versioned map spec (`maps/<name>.yaml`: map ID, directory, WMO path, placement; later a tile list) → `.wdt` into the build output, **never into Git**. It is recorded in the same manifest (version, sha256, base fingerprint). | #409 toolchain (new output type) | One spec format for every WMO-only map. Terrain maps extend the same spec with a tile list. It checks that the referenced WMO exists in the base file list, and fails on an unknown path. | Path (a) needs one such file per map, and this makes it reproducible. | S (warcraft-rs `wow-wdt` or ~100 lines Python, with a synthetic round-trip test) | 2 |
| **T5** | **Server data build per map spec**: from the same `maps/<name>.yaml`, run T1 extraction for the listed IDs into `data-v<date>` with SHA256SUMS; emit the `map_template` row and dungeon-clear roster lines as a migration draft. | twow-repo (script) + twow-core (migration) | Driven by the spec, so the client and server sides of a map cannot diverge. | One source of truth per map. | M | 3 |
| **T6** | **Travel node generator for any map**: take positions (entrance, boss, graveyard, portal targets) from the DB for a given map ID, and write `ai_playerbot_travelnode` rows as a migration; paths are then built on the mmaps at startup (3.3). It runs against a **copy** of the node tables and diffs before/after. | twow-core module tool or twow-repo `ops/` | Input is a map ID plus DB content; no per-map code. It also works for today's instance maps without nodes. | Bots reach and path inside every new instance without manual debug commands. | M | 3 |
| **T7** | **Generic `custom_dungeon_portal` script**: a GO portal whose target map and position come from data (`gameobject_template.data*` or a small table), refused while the target map is "unreleased" in T2's list. | twow-core (C++) | One script for all 13 existing Turtle portals and every future map. | Server-only entrance, with no `AreaTrigger.dbc` coupling. | S–M | 3 |
| **T8** | **Login guard for unreleased maps**: a character saved on a map outside the released list goes to its homebind at login, with a `[MapGuard]` log line. The released list is the one T2 produces. | twow-core (C++) | Data-driven list, no hard-coded 45. | Automates the manual Luigi fix of 2026-09-28 (#408). | S | 3 |
| T9 | **ADT sanitiser / validator** for path (c): strip `MFBO`/`MTXF`, check the `MPHD` big-alpha/MCCV flags, report `MH2O` without `MCLQ`, per client-version profile. | #409 toolchain | Profiles per target version, not a one-off script. | The missing link between Noggit output and 1.12. | M | 4, only if path (c) is chosen |

### 6.3 Mapping to the principle

| Principle point | How the map tools meet it |
|---|---|
| 1 General | Rules and specs over all map IDs (T2–T6); no ID or DBC hard-coded; archive order from one definition (T1). |
| 2 Data-driven | Map specs (`maps/*.yaml`) and DBC deltas in Git; outputs (WDT, DBC, MPQ, `data-v<date>`) versioned with sha256 in the #409 manifest. |
| 3 Tested | Synthetic mini WDT/DBC round trips (T3/T4); the T1 contract test (unchanged client → byte-identical output); T2 is the fixed consistency step. |
| 4 Documented | Each tool gets a README section in the #409 toolchain, including "how to add a new map" and "how to add a binding". |
| 5 Across versions | Bindings per client version, the base fingerprint from #410 step 1, pinned extractor version = the core pin; an unknown base or layout stops with a clear error. |
| 6 Local and cloud | Everything in the `extractor`/toolchain containers; the cloud runs the tests on synthetic data, and the owner or OB-15 runs the real build on the host. |

## 7. Staged plan with acceptance checks

Each stage is its own PR (tools in twow-repo, core changes in twow-core). Every
deploy and every client release needs the owner's approval. **Stage M0 depends
on #409 stage 1** (the toolchain: delta format, WDBC reader/writer, `dbcdiff`,
consistency check). **M1 depends on the #410 pipeline working end to end** (a
test patch delivered to one friend). T2/T3/T4 are PRs against that toolchain.

### Stage M0: tooling and checks (no new map)

- **Scope:** T1, T2; `MoveMapGen 169` into a new `data-v<date>` (#408 gap).
- **Acceptance:**
  - T1: extracting the unchanged client **with and without** the new option
    gives byte-identical `maps/`, `vmaps/`, `dbc/` (no behaviour change for the
    numeric patches). A contract test pins the archive list.
  - T2 on today's data reproduces OB-30's table: 45 client-missing; 169
    mmaps-missing; 44, 37, 50, 804, 806, 809 flagged. After `MoveMapGen 169`,
    169 is ok.
  - The live data mount stays untouched until the owner switches `DATA_PATH`.

### Stage M1: pilot map, client side (path a)

- **Scope:** T3, T4; the WMO choice (decision 8.4); the new `Map.dbc`/`AreaTable`
  rows and WDT through the #410 pipeline, in a `patch-X.mpq` test version.
- **Acceptance:**
  - `dbcdiff` shows **only** the declared new rows (#410 step 6);
  - **Test A1:** a GM `.go`/`.tele` to the new map ID on the owner's client loads
    the WMO. There is no loading hang, and the minimap/zone name is as declared.
  - A client **without** the patch never gets a way into the map (T2
    "unreleased" until the release).

### Stage M2: pilot map, server side

- **Scope:** extraction with T1 into `data-v<date>`; a migration with
  `map_template`, the new spawn layout, portal GO + T7 (or a trigger + coupled
  `AreaTrigger.dbc`, decision 8.5); dungeon-clear roster lines (T5); T6 nodes.
- **Acceptance:**
  - T2 all ok for the new ID;
  - mobs stand on the floor, have LoS and path (no straight-line fallback);
  - a bot group with dungeon-clear clears the first boss;
  - the startup log shows no vmap/mmap errors for the ID;
  - mangosd RAM before/after is recorded.

### Stage M3: release to the friends

- **Scope:** a coupled release under one version `N` (#410 decision 12): the
  client asset plus the server data mount plus the migration.
- **Acceptance:** one friend plays the entrance → first boss → leave, and the
  Luigi case cannot recur (T8 or the pre-deploy check).

### Stage M4 (optional): new terrain research, path (c)

- **Scope:** tests C1–C3 on a **throwaway test map**, never on a live one:
  - **C1:** a Noggit 3.3.5 tile with big alpha off loads in 1.12 with correct
    texture blending;
  - **C2:** the MCLQ export gives visible, swimmable water in 1.12;
  - **C3:** a WBS-exported WMO and a jM2converter `-cl` doodad render in 1.12.
- **Acceptance:** all three pass → a separate decision on a real terrain
  project. Any fail → path (c) is shelved and recorded.

## 8. Open owner decisions

Each decision comes with a recommendation.

1. **Pilot path.** Recommendation: **(a) reuse an existing WMO under a new map
   ID**, with the Scarlet Citadel content. (b) is not possible; (c) only after
   stage M4.
2. **Map ID range for our own maps.** Recommendation: **a reserved block below
   1000 that neither Blizzard nor Turtle uses**. Proposal: **900–949**, checked
   against the client's `Map.dbc` by T2 before first use. IDs of 1000 and above
   are not used (file naming, 3.2).
3. **Reuse map ID 45 or take a new ID.** Recommendation: **a new ID from the
   block** (e.g. 900).
   - 45 is Turtle's ID and carries old spawns, `game_tele` history and saved
     characters (Luigi).
   - The content is moved by a migration: templates stay, new spawns go on the
     new ID, and map 45's rows stay dormant as decided in #408.
4. **Which WMO.** Recommendation: **a Scarlet Monastery wing (map 189 family)**,
   for lore fit with "Scarlet Citadel". Alternative: the old `Monastery` WDT
   (map 44 in the 2025 client), once OB-30 checks what its WMO actually is.
5. **Entrance mechanism.** Recommendation: **a portal GO with the new
   `custom_dungeon_portal` script (T7)**. It is server-only and needs no
   `AreaTrigger.dbc` coupling, and it also fixes the 13 Turtle portals later. A
   trigger entrance only if the owner wants the classic walk-in instance feel.
6. **Instance type and size.** Recommendation: follow the existing
   `map_template` 45 (raid, 40 players, 7-day reset) only if the bot raid
   (Dragonslayer formation, #389) is ready. Otherwise a **dungeon for 5–10**,
   with bosses scaled by OB-20.
7. **Extractor change in the core (T1).** Recommendation: **approve it** as a
   twow-core PR (tool code only; the server binary is unaffected).
8. **Where extraction runs.** Recommendation: **the `extractor` compose service on
   the owner's host**, client mounted read-only, output into `data-v<date>`,
   never the live path. This is OB-30's plan in #408, which stays as it is.
9. **Path (c) research budget.** Recommendation: **not before the pilot ships**.
   Then stage M4 as a time-boxed experiment (tests C1–C3).
10. **Travel node generation on a copy.** Recommendation: **yes**. Every node
    change (T6) is tested on a copy of `ai_playerbot_travelnode*` first, because
    `saveNodeStore` rewrites the whole table.
11. **Login guard (T8) vs a one-off check.** Recommendation: **the guard**. It is
    small, and it covers every future unreleased map, not just 45.

## 9. Sources

**Code read for this document** (cloned read-only into the session scratchpad,
nothing vendored):

- twow-core `15fc5da` (core pin in twow-repo `6a5ad6d`, same content in the
  paths read), twow-repo `90834ea`: files and lines as cited.
- PR #410 `docs/design/client-patch-pipeline.md` @ `121a0b2`.
- #409 owner tool principle ([issuecomment-5874344129](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5874344129)) and the stage-1 toolchain brief and plan ([issuecomment-5874183685](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5874183685), [issuecomment-5874199786](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5874199786)).
- wowdev/noggit3 @ `59e58ad` (GPL-3.0, `COPYING`):
  <https://github.com/wowdev/noggit3>. In particular:
  - `src/noggit/MapTile.cpp`, `MapChunk.cpp`, `MapHeaders.h`,
    `liquid_chunk.cpp`, `ui/About.cpp`;
  - commit `2893aadc` for the MCLQ export.
- Noggit Red @ `b274edb` (GPL-3.0): <https://gitlab.com/prophecy-rp/noggit-red>.
  In particular:
  - `src/noggit/project/ApplicationProject.{h,cpp}`;
  - `ui/windows/settingsPanel/SettingsPanel.ui`;
  - `ui/tools/MapCreationWizard/`.
- tswow/noggit3 @ `29a1557` (archived): <https://github.com/tswow/noggit3>;
  azerothcore/noggit @ `19f408f`: <https://github.com/azerothcore/noggit>.
- warcraft-rs @ `76bedfd` (MIT or Apache-2.0):
  <https://github.com/wowemulation-dev/warcraft-rs>. In particular:
  - `file-formats/world-data/wow-adt/src/converter.rs`;
  - `docs/src/formats/world-data/wdt.md`;
  - `docs/src/convert-testing-results.md`.
- WoW Blender Studio @ `8512169` (GPL-3.0):
  <https://gitlab.com/skarnproject/blender-wow-studio>. In particular
  `io_scene_wmo/ui/panels.py`, `ui/operators.py`, `wmo/wmo_scene_group.py`.
- WMVx @ `90a4d9e` (GPL-3.0): <https://github.com/Frostshake/WMVx>.
- jM2converter @ `b9dcb83` (GPL-2.0): <https://github.com/WowDevs/jM2converter>,
  `src/koward/Constants.java`.
- WDBX Editor @ `d34cee1` (no licence file):
  <https://github.com/WowDevTools/WDBXEditor>, `Definitions/Classic 1.12.1 (5875).xml`.
- WoWDBDefs @ `e989e99`: <https://github.com/wowdev/WoWDBDefs>, `definitions/{Map,
  AreaTable,LoadingScreens,WorldMapArea,AreaTrigger}.dbd`.

**Public sources** (**[community]**; search excerpts only, direct access blocked):

- wowdev wiki, *ADT/v18*: <https://wowdev.wiki/ADT/v18>; *DB/Map*: <https://wowdev.wiki/DB/Map>
- WoW Modding, *ADTConverter*: <https://www.wowmodding.net/files/file/78-adtconverter/>
  (source of the "WotLK ADTs work in vanilla except water" excerpt)
- Marlamin, *MapUpconverter*: <https://github.com/Marlamin/MapUpconverter> (upward only)
- MaxtorCoder, *MultiConverter*: <https://github.com/MaxtorCoder/MultiConverter> (to 3.3.5)
- Bar3b0n3s, *Converter (wotlkconv)*: <https://github.com/Bar3b0n3s/Converter> (to 3.3.5)
- Marlamin's blog, *WoW Modding 102 – Noggit*: <https://blog.marlam.in/modding-wow-part2/>
- nogg-it blog (Noggit history, Cryect, 1.12 origin): <https://nogg-it.blogspot.com/>
- Turtle forum, *Importing Custom Models into WoW (1.12.1) with WoW Blender Studio 3.1*:
  <https://forum.turtlecraft.gg/viewtopic.php?t=9360> (blocked; title only)
- WoWEmu.org, *[TUTORIAL] Custom Dungeon*: <https://wowemu.org/threads/tutorial-custom-dungeon.366/>
- Blender WMO scripts (predecessor of WBS):
  <https://github.com/WowDevTools/Blender-WMO-import-export-scripts>
