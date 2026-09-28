# Map and dungeon tooling: formats, editors, server side, pilot path

Refs #412. Status: **design only**. This document changes no code, config, DBC,
SQL or client file. It adds no binaries and no Blizzard or Turtle client data
(ADT, WDT, WMO, M2, DBC).

**Inputs:**

- the "Cloud-Auftrag (OB-00, 28.09.2026)" comment in #412, which is this
  document's brief;
- the #412 body and the Noggit note under it;
- #408: the static audit (PR #411), OB-30's per-map check, and the owner
  decision on map 45 ("let it rest and secure it", twow-core#198);
- the client patch design in PR #410 (`docs/design/client-patch-pipeline.md`,
  revision 2 plus the OB-20/OB-15 additions). This document **builds on it and
  does not repeat it**: `patch-X.mpq`, Nostalgia, `dbcdiff`, the CONSIST step,
  releases and the legal frame are all defined there.

**Goal (owner):** tools for our own worlds, instances and dungeons, and a view of
how far we can integrate them and build our own tools around them.

**Short answer:**

- **No editor writes 1.12 maps today.** Every maintained Noggit variant loads
  only a 3.3.5a client. The only 1.12-era Noggit (Cryect, 2007) has no source
  anywhere we could find.
- **No converter takes a map from 3.3.5 to 1.12 end to end.** There are
  fragments:
  - Noggit's "MCLQ export" writes vanilla-style liquids into ADTs;
  - warcraft-rs has an unused MH2O → MCLQ function;
  - jM2converter is a prototype M2 down-porter.

  WMO group down-conversion is not implemented anywhere.
- **The realistic pilot is reuse:** an existing 1.12 instance's geometry under a
  new `Map.dbc` row. For a WMO-only instance, the new client files are **one
  small WDT plus DBC rows** in our `patch-X.mpq`. The Scarlet Citadel content
  from `tw_world` (map 45) is then re-placed on that geometry.
- Server side, our core is **already data-driven**. It needs:
  - `map_template` / `area_template` / `areatrigger_*` rows;
  - extracted maps/vmaps/mmaps;
  - an instance script, which the citadel already has.

  Two gaps block it:
  1. **the extractors cannot read our `patch-X.mpq`**: their archive lists are
     hard-coded to Blizzard/Turtle names (section 4.1);
  2. **a client without the patch hangs on the loading screen** when it is sent
     to the new map. This already happened with map 45 and the character Luigi.
- New terrain (Noggit, 3.3.5 → 1.12) is **not a pilot candidate**. It stays an
  optional research spike after the pilot (stage 5).

## Contents

1. [Evidence base and confidence markers](#1-evidence-base-and-confidence-markers)
2. [Formats: what a map is, and 1.12 vs 3.3.5](#2-formats-what-a-map-is-and-112-vs-335)
3. [Editors and tools](#3-editors-and-tools)
4. [Server side: our core](#4-server-side-our-core)
5. [Pilot path comparison](#5-pilot-path-comparison)
6. [Tools we could build ourselves](#6-tools-we-could-build-ourselves)
7. [Staged plan with acceptance checks](#7-staged-plan-with-acceptance-checks)
8. [Open owner decisions](#8-open-owner-decisions)
9. [Sources](#9-sources)

## 1. Evidence base and confidence markers

| Marker | Meaning |
|---|---|
| **[code]** | Read from `Cilverkrow/twow-core` `main` = `15fc5da` (2026-09-28) or `Cilverkrow/twow-repo` `main` = `90834ea`, with file and line. |
| **[repo:&lt;name&gt;@&lt;sha&gt;]** | Read from a shallow clone of a third-party repository at that commit (section 9), in the session scratchpad. Nothing was vendored. |
| **[dbd]** | WoWDBDefs `definitions/*.dbd` at `e989e99` (2026-09-25), build `1.12.1.5875` vs `3.3.5.12340`. |
| **[issue]** | Findings recorded in #408/#409/#410/#412 (OB-30 per-map check, owner live tests). |
| **[community]** | Search excerpts only. The session could not open wowdev.wiki, wowmodding.net, ownedcore.com, the Turtle forum or wiki (egress blocked), and the GitHub REST API returned 403. Not verified against the page text. |
| **[K]** | Known format behaviour from the modding community that the session **could not re-read** at a primary source (wowdev.wiki was blocked). To be checked before we rely on it. |
| **[speculation]** | Reasoned, not sourced. Each one has a test in section 7. |

The session had **no access to any game client**. No statement here comes from
reading client files. Client facts come from OB-30's read-only checks in #408.

## 2. Formats: what a map is, and 1.12 vs 3.3.5

### 2.1 The files that make a map or an instance

| File | What it is | Needed for |
|---|---|---|
| `World\Maps\<Dir>\<Dir>.wdt` | Tile table (which ADTs exist) + `MPHD` flags. **For a WMO-only instance** (most dungeons) it holds no tiles but one `MWMO`/`MODF` entry: the path and placement of the single world WMO. | client + extractors |
| `World\Maps\<Dir>\<Dir>_XX_YY.adt` | Terrain tile: height, textures, liquids, doodad/WMO placements. `MVER` 18 in both versions [repo:noggit3 `MapTile.cpp:84`; repo:warcraft-rs `adt.md:76`]. | client + extractors (only for terrain maps) |
| `World\Maps\<Dir>\<Dir>.wdl` | Low-resolution horizon heights. | client (terrain maps) |
| `World\wmo\...\X.wmo` + `X_NNN.wmo` | Building/dungeon root + group files, `MVER` 17 in both versions [repo:warcraft-rs `wow-wmo/src/version.rs`]. | client + vmap extractor |
| `*.m2` (+ `*.skin` from WotLK on) | Doodads, creatures. | client + vmap extractor (collision) |
| `*.blp` | Textures. BLP2 in both **[K]**. | client only |
| Minimap tiles, `Interface\WorldMap\...` BLPs | UI only. | client only, optional |

**DBC rows a map touches** (1.12.1.5875 layouts [dbd]):

| DBC | 1.12.1 fields | Client needs it for | Server loads it? [code] |
|---|---|---|---|
| `Map.dbc` | ID, **Directory**, InstanceType, MapType, MapName_lang, MinLevel, MaxLevel, MaxPlayers, Unk0–2, ParentMapID, MapDescription0/1_lang, **LoadingScreenID**, RaidOffset, Continentname, Unk4 | **without the row the loading screen hangs** (map 45, #408) | **no**: `map_template` (SQL) |
| `AreaTable.dbc` | ID, ContinentID, ParentAreaID, AreaBit, Flags, sound/ambience/music, ExplorationLevel, AreaName_lang, FactionGroupMask, LiquidTypeID[4] | zone name, exploration, music | **no**: `area_template` (SQL, `ObjectMgr.cpp:9601`) |
| `LoadingScreens.dbc` | ID, Name, FileName | the loading screen image (**reuse an existing ID**) | no |
| `AreaTrigger.dbc` | ID, ContinentID, Pos[3], Radius, Box_length/width/height/yaw (identical in 3.3.5) | which trigger the client reports on entry **[K]** | **no**: `areatrigger_template` (SQL) |
| `WMOAreaTable.dbc` | ID, WMOID, NameSetID, WMOGroupID, sound/ambience/music, flags, AreaTableID, name | area/zone **inside** a WMO | **yes** (`DBCStores.cpp`, list in 4.3) |
| `WorldMapArea.dbc` | ID, MapID, AreaID, AreaName, Loc* | world map (M key) | **yes** |
| `WorldMapOverlay.dbc`, `WorldMapContinent.dbc` | world map overlays / continents | world map | no |
| `DungeonMap.dbc` | **does not exist in 1.12.1** [dbd]; it is WotLK | – | – |

WoWDBDefs and WDBXEditor's 1.12.1 definition disagree on `Map.dbc` field 3
(MapType vs PVP) and field 11 (ParentMapID vs AreaTableID). The row generator
(section 6) must check both against a real base row before it writes anything.

### 2.2 What changes between 1.12 and 3.3.5

| Area | 1.12.1 | 3.3.5a | Source |
|---|---|---|---|
| ADT liquid | per chunk **`MCLQ`** (heights, 8×8 flags); liquid kind from `MCNK` flags 0x4/0x8/0x10/0x20 | **`MH2O`** in the root ADT | [repo:noggit3 `MapHeaders.h`] |
| ADT `MCNK` flags | 0x1–0x20 | adds `MCCV` 0x40, `do_not_fix_alpha_map` 0x8000, high-res holes 0x10000 | [repo:noggit3 `MapHeaders.h:7-25`]; the per-version split is **[K]** |
| Alpha maps | 4-bit, 2048 B per layer, "fixed" edge | 8-bit, optionally compressed, when WDT `MPHD` 0x4 ("big alpha") is set | [repo:noggit3 `MapChunk.cpp:1638`]; the details are **[K]** |
| `MCCV` (vertex colours), `MFBO` (fly bounds), `MTXF` | absent **[K]** | present (WotLK / TBC) | [repo:warcraft-rs `built_adt.rs`: TBC→Classic strips `MFBO`] |
| ADT chunk reading | "the 1.x client reads the MCNK chunks by their header offset and ignores the size" | – | [community] wowdev.wiki excerpt |
| WMO | v17, liquid in `MLIQ` | v17; `MOHD` flags 0x2/0x4/0x8 (unified render path, liquid-type DBC id, vertex-colour alpha fix) take effect | [repo:pywowlib `wmo_format_root.py:67`]; that 1.12 ignores them is **[K]** |
| M2 | version **256**, skins embedded | version **264**, external `.skin` (+ `.anim`) | [repo:warcraft-rs `wow-m2/src/version.rs:106-114`] |
| `Map.dbc` | 18 fields, 9-column locstrings | 22+ fields, 17-column locstrings (`LoadingScreenID` column 38 vs 57) | [dbd]; column arithmetic is ours |

**Consequence:** a 3.3.5 ADT is structurally close (same `MVER`). The breakers
are liquids (`MH2O`), alpha maps, `MCCV`, and above all **the assets it
references**. A 3.3.5 map placing WotLK M2s (v264) or WotLK-only textures does
not load in 1.12, even if the ADT itself were converted.

### 2.3 Converters in the 3.3.5 → 1.12 direction

| Tool | Commit, licence | What it really does | Verdict |
|---|---|---|---|
| Noggit3 "Use MCLQ liquids (vanilla/BC) export" | wowdev/noggit3 `59e58ad`, GPL-3.0 | Saves a **second copy** of each ADT with `MCLQ` instead of `MH2O` and clears `do_not_fix_alpha_map` (`SettingsPanel.cpp:179`, `MapTile.cpp:640-1027`, `MapChunk.cpp:1638,1901-1927`). It **keeps** `MCCV`/`MFBO` when present, and it keeps the WotLK asset references. | Partial ADT help |
| warcraft-rs (`wow-adt`, `wow-m2`, `wow-wmo`) | `76bedfd` (2026-07-09), MIT/Apache-2.0 | CLI `adt convert` to pre-WotLK drops `MH2O`/`MTXF` and passes chunks through. `convert_mh2o_to_mclq` exists in the library but is unused by the CLI. **WotLK→Classic is not in its test matrix** (`convert-testing-results.md`, 2026-01-11). WMO group conversion is "not yet implemented". | Partial, untested for our direction |
| jM2converter | WowDevs `b9dcb83` (2016), GPL-2.0 | M2 down-conversion with a `-cl` (classic) option; README: "still early prototype", known issues with ribbons, colours, shaders. | M2 only, prototype |
| wowlib (skarndev) | `ceddf16` (2026-09-28, single commit), MIT | Claims read/write for 1.12.1–11.x; "cross-version format conversion (scaffolding only)". | Not yet |
| AdtTools (kelno) | `92e1325`, **no licence file** | ADT tools for 2.4.3/3.3.5 including `CopyPreWotLKWater` (MCLQ); "I think this will work for 1.12 too". | Not tested for 1.12 |
| ADTConvert/ADTConvert2, MapUpconverter, MultiConverter, MoP→WotLK converters | various | **Up**-converters (3.3.5 → Legion/BfA+, or BfA → 3.3.5). | Wrong direction |

The tool names in the brief's search list ("ADTConverter", "WoWModelConverter",
"AllInOne converter") turned up **nothing verifiable**. A community thread
excerpt says "WotLK ADTs will work in vanilla, except … water" [community]. That
matches the table above, but it is not evidence that a whole map works.

## 3. Editors and tools

### 3.1 Noggit variants: does any of them support 1.12?

| Variant | Commit, licence | 1.12? (read from its source) |
|---|---|---|
| wowdev/noggit3 | `59e58ad` (2026-04-13), GPL-3.0 | **No.** It loads a 3.3.5 client only (MPQ list `common`, `expansion`, `lichking`, `patch…`, `application.cpp:103-123`). `Map.dbc` columns are hard-coded for 3.3.5. It **reads** `MCLQ` and can **export** it (2.3). |
| tswow/noggit3 | `29a1557` (2021), GPL-3.0 | Archived ("now maintained in the main noggit repository"). |
| azerothcore/noggit | `19f408f` (2017), GPL-3.0 | Old 3.3.5 Noggit. |
| jeddhor/noggit3 | `200b914` (2026-09-19), GPL-3.0 | Qt6 port of noggit3, same behaviour. |
| Noggit Red (prophecy-rp) | `b274edb` (2026-09-21), GPL-3.0 | Has a `ProjectVersion::VANILLA` enum, but `ApplicationProject.cpp` accepts only WotLK 3.3.5.12340 and SL 9.1.0; anything else logs "Unsupported project version". **No 1.12.** |
| Original Noggit (Cryect, 2007) | not found | Excerpt: "written for 1.12 … worked until Blizzard made changes to 2.0" [community]. **No source repository found.** |
| Hlkz/noggit, EmuZoneDEV/NOGgit3.1, AyaseCore | 2014–2019 | 3.3.5; EmuZoneDEV ships only binaries. |

**Answer to the brief:** no Noggit variant supports 1.12, neither reading a 1.12
client nor writing a clean 1.12 map. The best available route is to **edit in
Noggit against a 3.3.5 client**, then use the MCLQ export plus our own clean-up
(strip `MCCV`/`MFBO`, 4-bit alpha, only assets that exist in 1.12). Nobody has
published that clean-up (2.3). A Turtle forum excerpt says Turtle "uses
Noggit" [community]. Whether Turtle patched Noggit for 1.12 or back-ported from
3.3.5 is unknown, and no Turtle fork is public.

### 3.2 Other tools

| Tool | Commit, licence | Platform, UI, reproducible? | 1.12 | Use for us |
|---|---|---|---|---|
| **WoW Model Viewer** | wowmodelviewer `998f405` (2026-09-21), GPL-3.0 (installer/source headers; no root LICENSE) | Windows GUI; `-mpq` flag | "Load legacy MPQ client … same path for TBC/Vanilla" in its changelog; **1.12 model rendering not confirmed** | Viewing displays/models (owner has it at `Y:\WMV`). Not a map tool. |
| WoW Blender Studio | gitlab skarnproject `8512169` (2025-12-20), GPL-3.0 | Blender add-on, GUI | "3.3.5 and 7.3"; **no 1.12** | Out for now |
| Blender WMO import/export | WowDevTools `f0954b1` (2022), GPL-3.0 | Blender 2.79, deprecated | not stated | Out |
| **pywowlib** | wowdev `55276dc` (2026-07-05), MIT | Python library, scriptable | for 1.12.1: WMO ✔, M2 partial, ADT partial, MPQ ✔, BLP read, DBC ✔ | **Candidate library** for our WDT/WMO tools (section 6) |
| wowlib | skarndev `ceddf16`, MIT | C++/Python | claims 1.12 read/write; one commit old | Watch, don't depend |
| warcraft-rs | `76bedfd`, MIT/Apache-2.0 | Rust CLI, Linux/Windows | parses 1.12 ADT/WDT/WDL/WMO/M2 (tested on vanilla samples) | **Candidate** for validation/inspection in a container |
| **StormLib** | `44ebfbf` (2026-09-04), MIT | C library | MPQ v1 read/write **[K]** | Under mpqcli |
| **mpqcli** | TheGrayDot `d5c2bea` (2026-09-21), MIT | CLI, Linux/Windows | vanilla MPQ examples in its docs | **Already chosen in #410** for packing `patch-X` |
| Ladik's MPQ Editor | freeware, closed | Windows GUI, `/console` scripts | yes **[K]** | Manual inspection only (#410) |
| WDBX Editor | WowDevTools `d34cee1` (2020), **no licence file** | .NET GUI, Windows | ships a `Classic 1.12.1 (5875)` definition including `Map` | Manual inspection only; do not vendor |
| WoW-Spell-Editor (+ HeadlessExport) | see #410 3.1 | Windows | 1.12 bindings, **but none for Map/AreaTable/AreaTrigger/LoadingScreens/WMOAreaTable** | #410's DBC tool; map tables would need our own bindings |
| WoWDBDefs | `e989e99`, definitions CC BY-SA 4.0, code BSD-3 | data | 1.12.1.5875 layouts | **Field layouts** for our generator |
| Taliis | re-upload, no licence, last update 2009 | Java GUI | vanilla-era ADT/WDT/DBC [speculation] | Out |

### 3.3 Licences, and what that means for us

- **GPL-3.0/GPL-2.0:** all Noggit forks, WBS, WMV, jM2converter. We **run them as
  separate programs** and never vendor or link their code, so nothing we
  publish inherits the GPL. This is our reading, not legal advice.
- **Permissive:** StormLib, mpqcli, pywowlib, wowlib, warcraft-rs. These can be
  pinned dependencies of our container tools.
- **No licence file** (all rights reserved by default): WDBX Editor,
  WoW-Spell-Editor (#410), AdtTools, MultiConverter, Taliis. Local use only;
  never vendored.
- **WoWDBDefs definitions are CC BY-SA 4.0.** If our generator ships a derived
  layout table, it is attributed and share-alike. Generating it at build time
  from a pinned checkout avoids copying the data.
- **Windows GUI tools** (Noggit, WMV, WDBX, Ladik) run on the owner's host. That
  needs the owner's explicit approval under `AGENTS.md`'s host rule: a portable
  copy in a task directory, no installer, no PATH change. WMV already exists at
  `Y:\WMV`.

## 4. Server side: our core

### 4.1 Extractors: what exists, and two hard limits

The core carries the classic toolchain under `tools/` [code]:

| Tool | Source | Output | Notes |
|---|---|---|---|
| `mapextractor` | `tools/extractor/System.cpp` | `dbc/`, `maps/` (terrain height/area/liquid per ADT tile) | loops over **client `Map.dbc`** (`ReadMapDBC`, `:254-274`) and opens `World\Maps\<Directory>\<Directory>.wdt` (`:940`) |
| `vmapextractor` + `vmap_assembler` | `tools/vmap_extractor/vmapextract/vmapexport.cpp`, `tools/vmap_assembler/` | `Buildings/` → `vmaps/` (WMO/M2 collision per map) | also driven by client `Map.dbc` (`vmapexport.cpp:513-522`) |
| `MoveMapGen` | `tools/mmap/src/` | `mmaps/` (Recast navmesh) | discovers maps from the `maps/` and `vmaps/` file names (`MapBuilder.cpp:61-100`); `MoveMapGen <mapId>` builds one map; per-map settings in `mmapSettings.txt`, off-mesh links in `offmesh.txt` |

twow-repo already runs them in a container [code]:

- `deploy/compose/Dockerfile.tools` builds with `-DUSE_EXTRACTORS=ON` on Debian
  trixie;
- the `extractor` service (profile `tools`, `make extract`) mounts the client
  **read-only** and writes to `DATA_PATH`
  (`deploy/compose/docker-compose.yml:234-252`);
- `deploy/compose/extract-client-data.sh` runs all four steps. So "reproducible
  in Docker without client files in the image" is **already solved** (ADR-0023).

**Limit 1: our own `patch-X.mpq` is invisible to both extractors.**

- `mapextractor` opens a **fixed list**: `dbc.MPQ`, `terrain.MPQ`, `patch.MPQ`,
  `patch-2` … `patch-9.MPQ` (`System.cpp:100-113`).
- `vmapextractor` opens the base archives plus `patch.MPQ` and `patch-2` …
  `patch-99.MPQ` (`vmapexport.cpp:344-399`). **No letters.**
- Priority works as expected: every archive is `push_front`ed and searched first
  (`mpq_libmpq.cpp:51/54`), so the last opened wins.
- Consequence: a new `Map.dbc` row and a new WDT that live only in `patch-X.mpq`
  are **never seen**. Extraction would silently produce nothing for the new
  map, and extraction would disagree with the client about every file we
  override. This needs a small twow-core change: open `patch-[A-Z]` after the
  numbers in both extractors (the client's own order, #410 2.2), or take an
  explicit `-a <extra archive>` list. See tool W3.

**Limit 2: map IDs must stay below 1000.**

- Every data file name formats the map ID with three digits:
  - maps `maps/%03u%02u%02u.map` (`GridMap.cpp:602`);
  - vmaps `std::setw(3)` (`TileAssembler.cpp:110,157`, `MapTree.cpp:120`);
  - mmaps `mmaps/%03i.mmap` (`MoveMap.cpp:74,140`);
  - and `MoveMapGen` parses the ID back from the first three characters
    (`MapBuilder.cpp:71`).
- `map_template.entry` is `smallint unsigned`, but a four-digit ID would produce
  file names the loaders mis-split.
- Turtle's own maps are 800–822 [issue: OB-30]. Our range: **900–999** (decision
  8.10).

**Smaller points:**

- `extract-client-data.sh` is all-or-nothing per directory. It skips `maps/`
  once it is non-empty, so a new map is never added. Per-map runs need a
  wrapper (W3).
- `MoveMapGen`'s skip lists (`MapBuilder.cpp:430-466`) are hard-coded but do not
  touch 9xx IDs.
- A WMO-only instance has **no `.map` files**, only vmaps + mmaps. That is
  normal: OB-30 found the same for Stockade, WC, BFD, BRD and MC [issue].

### 4.2 What a new map or instance needs in the core

All of it is SQL in `tw_world` plus data files. **No core C++ change** is needed
for a plain instance [code]:

| Item | Where | Purpose |
|---|---|---|
| `map_template` row | `sql/base/tw_world_map_template.sql` (schema `:26-40`) | `entry`, `map_type` (1 dungeon / 2 raid), `player_limit`, `reset_delay`, `ghost_entrance_map/x/y` (release point after death), `map_name`, `script_name` |
| `area_template` rows | `tw_world_area_template.sql` | zone/area of the map; `LoadAreaTemplate` builds the per-map area-flag fallback (`ObjectMgr.cpp:9601-9608`) |
| Entrance | `areatrigger_template` + `areatrigger_teleport`, **or** a GO with a teleport script | see below |
| Exit | a second `areatrigger_teleport` inside the instance, or a GO | – |
| `game_tele` row | GM convenience | – |
| Spawns, loot | `creature`, `gameobject`, loot tables | the citadel's already exist on map 45 [issue] |
| Instance script | `src/scripts/...`, name in `map_template.script_name` | `instance_scarlet_citadel` exists (`src/scripts/dungeons/scarlet_citadel/`, 4,065 lines) |
| Graveyard | instances use `ghost_entrance_*`; open-world maps need `WorldSafeLocs.dbc` + `game_graveyard_zone` | – |
| Data files | `maps/` (terrain only), `vmaps/`, `mmaps/` | pathfinding for NPCs and **bots** |

**Entrance: area trigger or portal GO.**

- The client reports an area trigger only if the trigger is in **its own**
  `AreaTrigger.dbc` **[K]**. The server then checks `areatrigger_template`. A
  new trigger is therefore a **client + server pair**, and #408 already found
  the drift risk (trigger 5340: map 0 in the DB, entrance on 532).
- A **portal GO** needs no client DBC at all: the server teleports on use.
- Turtle's portals use the script name `custom_dungeon_portal` (13 GOs,
  including the citadel's 112920 [issue: PR #411]), and **no C++ script
  registers it**.
- Implementing that one script is server-only and would also serve our own
  maps. Recommendation: **portal GO** (decision 8.5).

**WMO area inside a reused WMO [code]:**

- Inside a WMO the server takes the area from `WMOAreaTable.dbc`, keyed by the
  WMO's own **root ID** (`MOHD` WMOID) plus the group ID
  (`GridMap.cpp:928-933`, `DBCStructure.h:832-837`). The map ID plays no part.
- So a **reused WMO keeps its original area**. A copy of a Scarlet Monastery
  wing reports the Scarlet Monastery zone, even under a new map ID.
- On the client, the same holds for the zone name **[K]**.
- To get our own area, the copied **root** WMO needs a new WMOID. That means a
  byte patch in `MOHD` and copies of all its group files, because they are
  named after the root. It also needs new `WMOAreaTable` rows, and **the server
  loads that DBC**, which makes it a **coupled release** (#410 5.5).
- For the pilot we accept the original area (decision 8.6, stage 2 measures
  the effects).

### 4.3 DBCs the server loads (why most map rows are client-only)

The server loads 44 DBCs (`DBCStores.cpp`). For maps, the relevant ones are
`WMOAreaTable`, `WorldMapArea` and `WorldSafeLocs`. **Not** loaded: `Map`,
`AreaTable`, `AreaTrigger` and `LoadingScreens`. The server uses SQL for those
(#410 2.3).

So the new map's `Map.dbc` / `AreaTable.dbc` / `LoadingScreens.dbc` rows are
**client-only** and may ship alone. Their drift against `map_template` /
`area_template` is exactly what #410's CONSIST step 2b reports. There is a
precedent for a server-side DBC row appender:
`twow-core/tools/dbc/add_worldsafelocs.py` adds graveyards 934/937/950 to
`WorldSafeLocs.dbc`.

### 4.4 Bots and dungeon-clear on a new map

- **Travel nodes** (`modules/mod-playerbots/src/playerbot/TravelNode.cpp`) [code]:
  - `loadNodeStore()` reads `ai_playerbot_travelnode*`. That is a module-owned
    world table, not an upstream schema.
  - A node stored with `linked = 0` sets `hasToGen`
    (`TravelNode.cpp:3466-3470`). On the next start `generateAll()` computes
    only the missing paths and saves them (`:3211-3230`, `TravelMgr.cpp:1863-1869`).
  - An **empty** table triggers a full regeneration (`:3478-3480`).
  - So a new map needs **seeded nodes** (entrance, bosses, exit), not a full
    rebuild. That is tool W6.
  - `generateAreaTriggerNodes` and `LoadMapTransfers` also pick up
    `areatrigger_teleport` pairs, so an area-trigger entrance gives bots a map
    transfer for free. With a portal GO, the transfer must be seeded
    [speculation; checked in stage 3].
- **mod-dungeon-clear**:
  - routes are computed "from the live navmesh", so without **mmaps** there is
    no clear;
  - boss-to-boss routes can be recorded (`DcRouteRecorder.cpp`,
    `tools/gen_routes.py`) into `routes/Route_<map>_<boss>.route`, and routes
    already exist for Turtle maps 816/820/822;
  - a new map therefore needs mmaps, then a recorded route set.

### 4.5 Failure mode: a client that does not know the map

- The server can send any client to any `map_template` ID. A client without the
  `Map.dbc` row **hangs on the loading screen**.
- The character then stays **saved on that map** and cannot log in again. That
  happened with Luigi on map 45 and was fixed by hand in the live DB [issue:
  #408, 2026-09-28].
- #410's version check only **warns**. For our own maps, a warning is not
  enough, because the failure strands the character.
- So the pilot needs two guards (decision 8.8):
  1. **the entrance checks a condition** that only patched players meet;
  2. **a login guard**: a character saved on a custom map whose client patch
     level is unknown or too old goes to the map's `ghost_entrance` instead.

  The server cannot read the MPQ, so "patch level" has to come from the TWPatch
  addon (#410 5.4) or from an owner-set account flag. That is a small twow-core
  feature; its design belongs to stage 3.

## 5. Pilot path comparison

Starting point [issue: #408]:

- the citadel content is in `tw_world`: map 45, 23 creatures, 12 GOs, 11 bosses,
  loot, and an instance script with 4 boss scripts;
- **no Turtle client has map 45**: it is missing from both clients' `Map.dbc`,
  and there is no WDT or ADT;
- twow-core#198 secures the dead entrance.

The spawns sit in a compact box: x 10–421, y −157–63, z 16–36, two levels
(about z 16 and z 33) [code: `sql/base/tw_world_creature.sql`]. That is typical
of a single-WMO instance in local coordinates, whose geometry Turtle never
shipped.

The boss and trash scripts carry **59 hard-coded coordinate triples**
(`boss_ardaeus.hpp` 14, `boss_daelus.hpp` 6, `boss_mariella.hpp` 4,
`trashbosses_scarlet_citadel.hpp` 20, `trashmobs_scarlet_citadel.hpp` 15).
Examples are sun move points, add spawns, and a "fell below z" check.

| | (a) reuse existing geometry under a new map ID | (b) Turtle map 45 data server-side | (c) new terrain, Noggit 3.3.5 → 1.12 |
|---|---|---|---|
| What it is | New `Map.dbc` row (new `Directory`) + a **copy of an existing WDT**. For a WMO instance, the WDT points at the **unchanged** original WMO, so only the WDT is copied (a few hundred bytes **[K]**). Terrain maps also copy WDL/ADTs. | There is **no map-45 client or geometry data** anywhere (#408). All that exists is DB content + scripts. So (b) is **not a path of its own**. It is the **content half** of (a). | Build terrain in Noggit against a 3.3.5 client, MCLQ export, strip `MCCV`/`MFBO`, 4-bit alpha, only 1.12 assets, new WDT/`Map.dbc` row. |
| Client files in `patch-X` | 1 WDT + DBC rows (`Map`, optional `AreaTable`, `LoadingScreens` reused) | – | WDT, WDL, N ADTs, minimap tiles, maybe WMOs |
| Server | `map_template`, `area_template`, portal/trigger, extraction (after W3) | spawns/scripts moved to the new geometry | same as (a) + terrain `maps/` |
| Content work | place spawns on the new geometry; re-point 59 script coordinates | reuses 11 boss scripts and loot (the valuable part) | everything from scratch |
| Effort | **S–M** for the map (1–2 days incl. extraction), **M** for re-placing the citadel content | included in (a) | **L–XL**: unknown tool chain, a 3.3.5 client on the host, our own ADT clean-up tool |
| Risk | Low–medium. The shared WMO keeps its original area (4.2). The client caches WMO by path, which is harmless **[speculation]**. The copy technique is documented for other versions [community: OwnedCore "Copying instances to custom ID"], and Turtle's new maps 800–822 show the client takes new `Map.dbc` rows [issue]. | Low (the data is ours, from `sql/base`) | High: no proven converter, and every asset reference must exist in 1.12 |
| Legal | The WDT copy and DBC rows are **client-derived** and go only into the private `patch-X` (#410 6). Git holds only the tool and our own values. | content is already in twow-core `sql/base` | Our own terrain, but built on Blizzard textures and models, so the same private distribution |
| Client distribution | #410 pipeline: asset `patch-X-v<N>.mpq`. Map rows are client-only, the release goes alone. | – | same, larger MPQ |

**Recommendation: (a) with the content of (b)**, in two steps:

1. A **technical spike** on a small, well-known WMO instance, to prove the
   chain: copy the WDT → client loads → extraction → mmaps → bots path.
   Candidate: Stormwind Stockade (map 34) under a 9xx test ID.
2. The **citadel pilot** on a geometry OB-20 picks for size and theme (decision
   8.3).

(c) becomes a separate, optional spike (stage 5), only if the owner wants
real new terrain after the pilot.

Which geometry fits the citadel is an **OB-20 content decision**. Selection
criteria:

- room for 11 boss areas;
- two floor levels;
- theme;
- no conflict with the source instance's own players, which is not a real
  issue on our small realm.

Candidates are Scarlet Monastery wings or other WMO instances. We look at them
in WMV (owner host) and walk them in-game before choosing. Map 45's own
coordinates **do not** carry over, so all spawns are re-placed.

## 6. Tools we could build ourselves

All tools live in `twow-repo` under `ops/map-tooling/` (proposed). They follow
#410 3.3:

- Python in a pinned container (Debian trixie);
- they read the client **read-only**;
- output goes to the owner's task directory;
- **nothing client-derived goes into Git**.

Extractor changes are twow-core PRs.

| # | Tool | What it does | Benefit | Effort | Order |
|---|---|---|---|---|---|
| **W1** | **Map inventory / consistency report** | For every map: `map_template` row, client `Map.dbc` row (per MPQ, with the winning archive), WDT present, `maps/`/`vmaps/`/`mmaps/` present, `area_template` zone, entrances (`areatrigger_teleport`, portal GOs with a working script). Plus `areatrigger_template` vs client `AreaTrigger.dbc`. Writes CSV + Markdown. | It would have found map 45, the missing mmaps for 169, and trigger 5340 in one run. It is the **map half of #410's CONSIST step 2b**, and both should share one implementation. | S | 1 |
| **W2** | **DBC row generator** (`Map`, `AreaTable`, `LoadingScreens`, `AreaTrigger`, `WMOAreaTable`) | Appends or changes rows from a small YAML of **our own values**. Layouts come from WoWDBDefs 1.12.1.5875, cross-checked against a real base row (field 3/11 disagreement, 2.1). Checked by #410's `dbcdiff` (only declared rows differ). The precedent is `add_worldsafelocs.py`. | Map rows without Windows and without Spell-Editor bindings; Linux-reproducible | S | 2 |
| **W3** | **Extractor fixes + per-map wrapper** | twow-core: both extractors also open `patch-[A-Z].mpq` (or take `-a <archive>`). twow-repo: a wrapper that extracts **only listed map IDs** (`MoveMapGen <id>`) into a new data version `data-v<date>` with `SHA256SUMS` and a manifest (tool commit, MPQ hashes, map list), as OB-30 proposed in #408. It checks that existing maps come out byte-identical. | Removes limit 1 (4.1); no hour-long full rebuild per map | M | 2 |
| **W4** | **Map clone tool** | From a source map's `Directory`: copy the WDT (+ WDL/ADTs for terrain maps) under a new directory name into a staging tree for `patch-X`. Optional mode: copy a root WMO + groups with a new `MOHD` WMOID (for our own area, decision 8.6). Uses pywowlib or our own minimal chunk reader. | The core of path (a) | S (WDT) / M (WMO mode) | 3 |
| **W5** | **Instance SQL scaffold** | Writes an idempotent world migration (`sql/database_updates/<ts>_world.sql`, twow-core conventions): `map_template`, `area_template`, portal GO + template or trigger pair, exit, `game_tele`, `ghost_entrance`. Values come from the same YAML as W2, so client and server rows cannot drift. | One source of truth for client + server map data | S | 3 |
| **W6** | **Bot travel-node seeder** | From the YAML and the spawn table: inserts `ai_playerbot_travelnode` rows (entrance, each boss, exit) with `linked = 0`, so the next start generates only their paths (4.4). The map-transfer node pair is included when the entrance is a portal. | Bots can travel to and inside the map without a full regeneration | S–M | 4 |
| W7 | Dungeon-clear route recording | Uses the existing `DcRouteRecorder` / `gen_routes.py`; no new tool, just a runbook step. | Autonomous clears on the new map | S | 4 |
| W8 | Spawn/script coordinate transform | Moves a spawn set and script constants by translation/rotation. **Only useful if** the new geometry matches the old layout, which it does not for the citadel. | Low. Re-place by hand with `.gps` instead. | S | – (not recommended) |
| W9 | 1.12 ADT clean-up (post-Noggit) | Strip `MCCV`/`MFBO`/`MTXF`, 4-bit alpha, validate every referenced asset exists in the 1.12 client listfile | Needed only for path (c) | L | 5 (optional) |

**Why W2 is our own and not Spell-Editor bindings:**

- #410 uses WoW-Spell-Editor for spells, because of its editing UI and its
  import.
- The map tables are a handful of rows with values we author, and they need no
  UI.
- A 150-line Python writer runs in the Linux container, and the same
  `dbcdiff` guards it.
- Both routes produce the same file.

Decision 8.4.

## 7. Staged plan with acceptance checks

Each stage is its own PR: tools in twow-repo, extractor/core changes in
twow-core. Every deploy needs the owner's approval. **Prerequisite for stages
2+: #409 stage 1 is done**, meaning `patch-X` reaches the owner and one friend,
and T4 has passed.

### Stage 1: inventory (W1)

- **Scope:** W1 as a read-only container tool against the client (ro), the
  server `data/` and a disposable DB with `sql/base` + migrations.
- **Acceptance:**
  - the report lists at least the known findings: map 45 (server only, no
    client row), 169 (mmaps missing), 44/37/804/809 (empty or old), trigger
    5340;
  - every map in the current client has a status;
  - repeated runs give identical output.

### Stage 2: extraction fix + clone spike (W2, W3, W4 WDT mode, W5)

- **Scope:**
  - the twow-core extractor PR (`patch-[A-Z]` or `-a`);
  - the per-map wrapper;
  - a test map `9xx` = a clone of Stormwind Stockade (map 34);
  - a test `patch-X` build carrying the `Map.dbc` row + WDT;
  - the `map_template`/`area_template` migration;
  - a GM-only `game_tele`.
- **Acceptance:**
  - the extraction of an **unchanged** client with the new extractor is
    byte-identical to today's `data/` for every existing map;
  - with the test patch, the extractor writes vmaps + mmaps for `9xx`, and
    nothing else changes;
  - the patched client loads `9xx` via `.tele`;
  - `.gps` shows the expected zone (the original Stockade area, 4.2), which is
    recorded;
  - a bot group paths inside;
  - map 34 itself is unchanged;
  - the unpatched client is **not** teleported, because the guard (4.5) is in
    place. Record the test with a GM character that has no patch;
  - mangosd RAM before/after is recorded.

### Stage 3: citadel pilot (content of (b) on geometry chosen in 8.3)

- **Scope:**
  - the clone of the chosen geometry;
  - the citadel's `map_template` row moved or copied per decision 8.2;
  - spawns re-placed by hand;
  - the 59 script coordinates re-pointed;
  - a `custom_dungeon_portal` implementation (a server-only portal teleport,
    usable for all 13 Turtle portals after review);
  - the login guard;
  - lifting twow-core#198's securing **for the pilot map only**;
  - W6 nodes;
  - W7 routes.
- **Acceptance:**
  - a patched player enters through the portal, clears all 11 bosses and gets
    loot;
  - the exit works;
  - a death releases to `ghost_entrance`;
  - bots follow in, fight, and dungeon-clear runs boss to boss;
  - an unpatched client cannot enter;
  - a character logged out inside with the patch removed logs in at the
    entrance, not stranded;
  - the startup log has no missing map/vmap/mmap errors for the map.

### Stage 4 (optional): own area (W4 WMO mode)

- **Scope:** new WMOID, new `AreaTable` + `WMOAreaTable` rows.
- **Coupled release:** client `patch-X` + server `WMOAreaTable.dbc` + restart,
  under one version `N` (#410 5.5).
- **Acceptance:**
  - `.gps` and the client show the new zone name inside the pilot map;
  - the source instance still shows its own.

### Stage 5 (optional): new-terrain spike (W9)

- **Scope:** one ADT tile built in Noggit against a 3.3.5 client, using only
  assets that exist in 1.12, run through the MCLQ export and W9.
- **Acceptance:**
  - the tile loads in the 1.12 client without artefacts: liquids, texture
    blending, doodads;
  - the extractors produce a `.map` and vmaps for it.

  Only then decide whether real new terrain is worth pursuing.

## 8. Open owner decisions

Each decision comes with a recommendation.

1. **Pilot path.** Recommendation: **(a) reuse geometry, with the citadel content
   from (b)**. (c) only as the optional stage 5.
2. **Map ID for the citadel pilot.** Recommendation: **keep ID 45**:
   - `map_template` 45, `instance_scarlet_citadel`, all spawns, loot and the
     instance binds already key on it;
   - 45 is free in every client `Map.dbc`;
   - since Turtle's shutdown, no future Turtle client will claim it.

   The alternative is a new 9xx ID, which means moving every row. With either
   choice, the release that gives 45 a client row also lifts twow-core#198's
   guard for 45.
3. **Which geometry for the citadel.** Recommendation: OB-20 chooses after stage
   2, from 2–3 candidates (Scarlet Monastery wings first, for the theme), looked
   at in WMV and walked in game.
4. **DBC row tool for map tables.** Recommendation: **our own Python generator
   (W2)** in the container, checked by `dbcdiff`. Spell-Editor bindings are not
   needed for these tables.
5. **Entrance type.** Recommendation: a **portal GO with a server-side teleport
   script** (implementing Turtle's `custom_dungeon_portal`). There is no client
   `AreaTrigger.dbc` row, and so no trigger drift. Exits likewise.
6. **Own area/zone for the pilot.** Recommendation: **no**. Accept the source
   WMO's area in stages 2–3 and measure the effects. Stage 4 only if they
   matter.
7. **twow-core extractor change** (`patch-[A-Z]` / `-a`). Recommendation: **yes**,
   as its own small PR with the byte-identity check of stage 2.
8. **Guard against unpatched clients** (4.5). Recommendation: **both**:
   - an entrance condition;
   - a login relocate for characters on custom maps.

   This covers the gap the Luigi incident showed. The patch-level source
   (TWPatch addon report or account flag) is decided in stage 3.
9. **New terrain / Noggit.** Recommendation: **defer** until after the pilot. It
   needs a 3.3.5 client on the owner's host (host approval), and nobody has
   shown a working 1.12 route yet.
10. **Map-ID range for our own maps.** Recommendation: **900–999**. It stays
    under the three-digit file-name limit (4.1) and clear of Turtle's 800–822.
11. **Third-party tools.** Recommendation:
    - GPL tools (Noggit, WMV) run as separate programs only;
    - tools without a licence (WDBX, Spell Editor) are local-only;
    - permissive libraries (pywowlib, StormLib, mpqcli, warcraft-rs) may be
      pinned container dependencies;
    - every Windows GUI tool on the host needs explicit approval under
      `AGENTS.md`.
12. **Who owns what.** Recommendation:
    - OB-30: W1, W3 (data/extraction);
    - OB-15: W2, W4 (client, `patch-X`);
    - OB-20: W5, content, portal script, guard;
    - OB-10: W6/W7 (bots).

## 9. Sources

**Our code** (`Cilverkrow/twow-core` `15fc5da`, `Cilverkrow/twow-repo` `90834ea`):

- `tools/extractor/System.cpp`, `tools/vmap_extractor/vmapextract/{vmapexport,mpq_libmpq}.cpp`,
  `tools/mmap/src/MapBuilder.cpp`, `tools/mmap/{mmapSettings,offmesh}.txt`,
  `tools/dbc/add_worldsafelocs.py`;
- `src/game/Maps/GridMap.cpp`, `src/game/Maps/MoveMap.cpp`, `src/game/vmap/{TileAssembler,MapTree}.cpp`,
  `src/game/Database/{DBCStores.cpp,DBCStructure.h}`, `src/game/ObjectMgr.cpp`;
- `sql/base/tw_world_{map_template,area_template,areatrigger_template,areatrigger_teleport,creature}.sql`;
- `src/scripts/dungeons/scarlet_citadel/*`;
- `modules/mod-playerbots/src/playerbot/{TravelNode,TravelMgr}.cpp`;
- `modules/mod-dungeon-clear/` (`README.md`, `src/.../DcRouteRecorder.cpp`, `routes/`);
- twow-repo `deploy/compose/{Dockerfile.tools,extract-client-data.sh,docker-compose.yml}`,
  `ops/assets/publish-client-data.sh`, ADR-0023.

**Third-party repositories** (shallow clones, read-only; commit and date as
observed on 2026-09-28):

- Noggit: <https://github.com/wowdev/noggit3> `59e58ad`;
  <https://github.com/tswow/noggit3> `29a1557`;
  <https://github.com/azerothcore/noggit> `19f408f`;
  <https://github.com/jeddhor/noggit3> `200b914`;
  <https://gitlab.com/prophecy-rp/noggit-red> `b274edb`;
  <https://github.com/Hlkz/noggit> `a27d4dc`;
  <https://github.com/EmuZoneDEV/NOGgit3.1> `75f3c0c`.
- Formats/converters: <https://github.com/wowdev/WoWDBDefs> `e989e99`;
  <https://github.com/wowemulation-dev/warcraft-rs> `76bedfd`;
  <https://github.com/WowDevs/jM2converter> `b9dcb83`;
  <https://github.com/skarndev/wowlib> `ceddf16`;
  <https://github.com/kelno/AdtTools> `92e1325`;
  <https://github.com/Luzifix/ADTConvert> `acd7b57`;
  <https://github.com/Kaev/ADTConvert2> `329d4df`;
  <https://github.com/Marlamin/MapUpconverter> `a4f4c1a`;
  <https://github.com/MaxtorCoder/MultiConverter> `22edb66`.
- Tools: <https://github.com/wowdev/pywowlib> `55276dc`;
  <https://gitlab.com/skarnproject/blender-wow-studio> `8512169`;
  <https://github.com/WowDevTools/Blender-WMO-import-export-scripts> `f0954b1`;
  <https://github.com/wowmodelviewer/wowmodelviewer> `998f405`;
  <https://github.com/WowDevTools/WDBXEditor> `d34cee1`;
  <https://github.com/ladislav-zezula/StormLib> `44ebfbf`;
  <https://github.com/TheGrayDot/mpqcli> `d5c2bea`;
  <https://github.com/vmangos/core> `4641790` (upstream comparison only).

**Community** (search excerpts only, pages blocked): wowdev.wiki *ADT/v18*
(MCNK offset note); wowmodding.net "WoD retro porting to Classic 1.12";
OwnedCore "[Guide] Copying Instances to custom ID" (thread 286031); Turtle forum
"What map editing software does TurtleWoW use?"; the original Noggit blog
(nogg-it.blogspot.com).

**Still to verify before relying on it** (all **[K]** items):

- the per-version split of `MCCV`/`MFBO`/`MTXF`;
- 4-bit vs 8-bit alpha;
- 1.12 ignoring the `MOHD` 0x2/0x4/0x8 flags;
- that the client reports only area triggers from its own `AreaTrigger.dbc`;
- the WDT size of a WMO-only map;
- which `Map.dbc` field 3/11 naming is right.

Stage 1/2 either reads these from the owner's client or tests them.
