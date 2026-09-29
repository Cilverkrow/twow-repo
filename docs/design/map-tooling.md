# Map and dungeon tooling: formats, editors, server side, pilot path

Refs #412, #427. Status: **design only**. This document changes no code,
config, DBC, SQL or client file. It adds no binaries and no Blizzard or Turtle
client data (ADT, WDT, WMO, M2, DBC).

**Inputs:**

- the "Cloud-Auftrag (OB-00, 28.09.2026)" comment in #412, which is this
  document's brief;
- the #412 body and the Noggit note under it;
- #408: the static audit (PR #411), OB-30's per-map check, and the owner
  decision on map 45 ("let it rest and secure it", twow-core#198);
- the client patch design in PR #410 (`docs/design/client-patch-pipeline.md`)
  and the stage-1 toolchain plan in #409. This document **builds on them and
  does not repeat them**: `patch-X.mpq`, Nostalgia, `dbcdiff`, the CONSIST step,
  the delta format, releases and the legal frame are all defined there;
- the owner's **tool principle** of 2026-09-28
  ([#409 issuecomment-5874344129](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5874344129)),
  which binds every tool in section 6.

**Revision 2 (2026-09-28).** It folds in:

- the OB-20 review and the OB-15 review of this PR;
- the parts of the parallel draft PR #424 that OB-20 asked to adopt:
  - WDT from a text spec;
  - "missing map data runs silently wrong";
  - `MoveMapGen 169`;
  - the map-44 `Monastery` WDT as a candidate;
- the owner decisions recorded in #427 and #409:
  - the citadel keeps map ID 45;
  - our own new maps use **900–949**;
  - path (a) or (c) is chosen at the start of train 10;
- a Turtle wiki note relayed by OB-00: the citadel was planned as a 40-player
  raid beneath the Scarlet Monastery and shelved because of instance-model
  problems.

Section 10 lists what changed.

**Goal (owner):** tools for our own worlds, instances and dungeons, and a view of
how far we can integrate them and build our own tools around them. The first
target is the playable Scarlet Citadel in train 10 (#427).

**Short answer:**

- **No editor writes 1.12 maps today.** Every maintained Noggit variant loads
  only a 3.3.5a client. The only 1.12-era Noggit (Cryect, 2007) has no source
  anywhere we could find.
- **No converter takes a map from 3.3.5 to 1.12 end to end.** There are
  fragments:
  - Noggit's "MCLQ export" writes vanilla-style liquids into ADTs;
  - warcraft-rs has an unused MH2O → MCLQ function and a downgrade chain that
    loses liquids;
  - jM2converter is a prototype M2 down-porter.

  WMO group down-conversion is not implemented anywhere.
- **Path (a), reuse:** an existing 1.12 instance's WMO under a new `Map.dbc`
  row. For a WMO-only instance, the new client data is **one WDT that we
  generate from a text spec in Git**, plus DBC rows in our `patch-X.mpq`. No
  Blizzard file is copied. The citadel content from `tw_world` (map 45) is then
  re-placed on that geometry. The Monastery is the leading geometry candidate.
- **Path (c), new terrain** (Noggit against a 3.3.5 client, then down-converted),
  stays open until train 10 starts (owner decision). It needs a spike first
  (stage 5), because nobody has shown a working 1.12 route.
- Server side, our core is **already data-driven**. It needs:
  - `map_template` / `area_template` / entrance rows;
  - extracted maps/vmaps/mmaps;
  - an instance script, which the citadel already has.

  Three gaps block it:
  1. **the extractors cannot read our `patch-X.mpq`**: their archive lists are
     hard-coded to Blizzard/Turtle names (section 4.1);
  2. **missing map data does not fail, it runs silently wrong**: no ground
     height, no line of sight, straight-line paths (section 4.1);
  3. **a client without the patch hangs on the loading screen** when it is sent
     to the map, and the character stays stranded there. This happened with map
     45 and the character Luigi. We need a login guard (section 4.5).
- **Effort for path (a)** (OB-20 estimate): **15–22 working days plus 3–5 owner
  sessions in game**. The biggest risk is that the unreleased boss mechanics
  may not fit the new room shape.

## Contents

1. [Evidence base and confidence markers](#1-evidence-base-and-confidence-markers)
2. [Formats: what a map is, and 1.12 vs 3.3.5](#2-formats-what-a-map-is-and-112-vs-335)
3. [Editors and tools](#3-editors-and-tools)
4. [Server side: our core](#4-server-side-our-core)
5. [Pilot path comparison](#5-pilot-path-comparison)
6. [Tools we could build ourselves](#6-tools-we-could-build-ourselves)
7. [Staged plan with acceptance checks](#7-staged-plan-with-acceptance-checks)
8. [Owner decisions](#8-owner-decisions)
9. [Sources](#9-sources)
10. [Changes in revision 2](#10-changes-in-revision-2)

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
(MapType vs PVP) and field 11 (ParentMapID vs AreaTableID). The M2 bindings
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

### 4.1 Extractors: what exists, two hard limits, and silent failure

The core carries the classic toolchain under `tools/` [code]:

| Tool | Source | Output | Notes |
|---|---|---|---|
| `mapextractor` | `tools/extractor/System.cpp` | `dbc/`, `maps/` (terrain height/area/liquid per ADT tile) | loops over **client `Map.dbc`** (`ReadMapDBC`, `:254-274`) and opens `World\Maps\<Directory>\<Directory>.wdt` (`:940`) |
| `vmapextractor` + `vmap_assembler` | `tools/vmap_extractor/vmapextract/vmapexport.cpp`, `tools/vmap_assembler/` | `Buildings/` → `vmaps/` (WMO/M2 collision per map) | also driven by client `Map.dbc` (`vmapexport.cpp:513-522`) |
| `MoveMapGen` | `tools/mmap/src/` | `mmaps/` (Recast navmesh) | discovers maps from the `maps/` and `vmaps/` file names, **not** from `Map.dbc` (`MapBuilder.cpp:61-100`); `MoveMapGen <mapId>` builds one map; per-map settings in `mmapSettings.txt`, off-mesh links in `offmesh.txt` |

twow-repo already runs them in a container [code]:

- `deploy/compose/Dockerfile.tools` builds with `-DUSE_EXTRACTORS=ON` on Debian
  trixie, from the `core` submodule, so the tools share the server's pin;
- the `extractor` service (profile `tools`, `make extract`) mounts the client
  **read-only** and writes to `DATA_PATH`
  (`deploy/compose/docker-compose.yml:234-252`);
- `deploy/compose/extract-client-data.sh` runs all four steps. "Reproducible
  in Docker without client files in the image" is **already solved** (ADR-0023).
- **Rule:** always point `DATA_PATH` at a new `data-v<date>` directory, never at
  the live one. OB-30 planned it this way in #408: side by side, with a manifest
  and `SHA256SUMS`, and rollback is the old mount.

**Limit 1: our own `patch-X.mpq` is invisible to both extractors.**

- `mapextractor` opens a **fixed list**: `dbc.MPQ`, `terrain.MPQ`, `patch.MPQ`,
  `patch-2` … `patch-9.MPQ` (`System.cpp:100-113`).
- `vmapextractor` opens the base archives plus `patch.MPQ` and `patch-2` …
  `patch-99.MPQ` (`vmapexport.cpp:344-399`). **No letters.**
- Priority works as expected: every archive is `push_front`ed and searched first
  (`mpq_libmpq.cpp:51/54`), so the last one opened wins.
- Consequence: a new `Map.dbc` row and a new WDT that live only in `patch-X.mpq`
  are **never seen**. Extraction would silently produce nothing for the new
  map, and extraction would disagree with the client about every file we
  override.
- This needs a small twow-core change: open `patch-[A-Z]` after the numbers in
  both extractors (the client's own order, #410 2.2), or take an explicit
  archive list. The list comes from the same load-order definition that the
  #409 build uses. That is tool M3.

**Limit 2: map IDs must stay below 1000.**

- Every data file name formats the map ID with three digits:
  - maps `maps/%03u%02u%02u.map` (`GridMap.cpp:602`);
  - vmaps `std::setw(3)` (`TileAssembler.cpp:110,157`, `MapTree.cpp:120`);
  - mmaps `mmaps/%03i.mmap` (`MoveMap.cpp:74,140`);
  - and `MoveMapGen` parses the ID back from the first three characters
    (`MapBuilder.cpp:71`).
- `map_template.entry` is `smallint unsigned`, but a four-digit ID would produce
  file names that the loaders mis-split.
- Turtle's own maps are 800–822 [issue: OB-30]. **Our block is 900–949**
  (owner decision, #427).

**Missing data does not crash. It runs silently wrong** [code; found by #424]:

- `GridMap::loadData` returns success when the `.map` file is missing ("Not
  return error if file not found", `GridMap.cpp:77-80`);
- a missing mmap logs at DEBUG only (`MoveMap.cpp:79`);
- `PathFinder` builds a **straight-line shortcut** when the navmesh or the
  tiles are missing (`PathFinder.cpp:104-111`);
- the only hard exit is for the six start areas on maps 0/1
  (`World.cpp:1981-1991`).

A map with a `map_template` row but without data therefore loads. It has no
ground height and no line of sight, and NPCs and bots walk through walls.
**The server will not report this, so M1 must** (section 6).

**Map 169 has no mmaps because of `--skipJunkMaps`** [code; #424]:

- `shouldSkipMap` lists `case 169: // EmeraldDream.wdt (unused, and very large)`
  under the default-on junk flag (`MapBuilder.cpp:449`);
- an all-maps run therefore skips it;
- **`MoveMapGen 169` builds it with no code change**, because a map number on
  the command line ignores the skip flags (`tools/mmap/readme`, "this command
  will build the map regardless of --skip* option settings");
- this is the only real data gap from #408, and it goes into OB-30's plan.

**Smaller points:**

- `extract-client-data.sh` is all-or-nothing per directory. It skips `maps/`
  once it is non-empty, so a new map is never added. Per-map runs need a
  wrapper (M3).
- `tools/mmap/mmap_extract.py` is Python 2 with a stale map list, and its readme
  says "DEPRECATED, NOT ACTUAL FOR TURTLE VERSION". Do not use it.
- A WMO-only instance has **no `.map` files**, only vmaps + mmaps. That is
  normal: OB-30 found the same for Stockade, WC, BFD, BRD and MC [issue].

### 4.2 What a new map or instance needs in the core

All of it is SQL in `tw_world` plus data files. **No core C++ change** is needed
for a plain instance; the portal script and the guard below are the exceptions
[code]:

| Item | Where | Purpose |
|---|---|---|
| `map_template` row | `sql/base/tw_world_map_template.sql` (schema `:26-40`) | `entry`, `map_type` (1 dungeon / 2 raid), `player_limit`, `reset_delay`, `ghost_entrance_map/x/y` (release point after death), `map_name`, `script_name`. For 45 it already exists (raid, 40, `instance_scarlet_citadel`). |
| `area_template` rows | `tw_world_area_template.sql` | zone/area of the map; `LoadAreaTemplate` builds the per-map area-flag fallback (`ObjectMgr.cpp:9601-9608`) |
| Entrance | a portal GO with a teleport script (recommended), or `areatrigger_template` + `areatrigger_teleport` | see below |
| Exit | a second portal GO inside, or a trigger | – |
| `game_tele` row | GM convenience | re-added in the release that opens 45 (twow-core#198 removed 500/819) |
| Spawns, loot | `creature`, `gameobject`, loot tables | the citadel's already exist on map 45 [issue] |
| Instance script | `src/scripts/...`, name in `map_template.script_name` | `instance_scarlet_citadel` exists (`src/scripts/dungeons/scarlet_citadel/`, 4,065 lines). OB-20 checked that **no script references map 45 directly**; the binding is `script_name` plus the spawn rows. |
| Graveyard | instances use `ghost_entrance_*`; open-world maps need `WorldSafeLocs.dbc` + `game_graveyard_zone` | – |
| Data files | `maps/` (terrain only), `vmaps/`, `mmaps/` | pathfinding for NPCs, **bots** and dungeon-clear |

**Entrance: portal GO rather than area trigger** (OB-15 and OB-20 agree):

- The client reports an area trigger only if the trigger is in **its own**
  `AreaTrigger.dbc` **[K]**. The server then checks `areatrigger_template`. A
  new trigger is therefore a **client + server pair**, and #408 already found
  the drift risk (trigger 5340: map 0 in the DB, entrance on 532).
- A **portal GO** needs, on the client side, only an **existing `displayId`**
  (reuse an existing portal model), and no client release at all. The server
  teleports on use.
- Turtle's portals use the script name `custom_dungeon_portal` (13 GOs,
  including the citadel's 112920 [issue: PR #411]), and **no C++ script
  registers it**.
- A **generic, data-driven** implementation is server-only. The target comes
  from data, and the script refuses maps that are not released (4.5). It
  serves all 13 Turtle portals and every future map.

**WMO area inside a reused WMO [code]:**

- Inside a WMO the server takes the area from `WMOAreaTable.dbc`, keyed by the
  WMO's own **root ID** (`MOHD` WMOID) plus the group ID
  (`GridMap.cpp:928-933`, `DBCStructure.h:832-837`). The map ID plays no part.
- So a **reused WMO keeps its original area**. A Scarlet Monastery WMO reports
  the Scarlet Monastery zone, even under map 45.
- On the client, the same holds for the zone name **[K]**.
- To get our own area, the WMO needs a new WMOID. That means a copy of the root
  WMO with a patched `MOHD`, and copies of all its group files, because they are
  named after the root. It also needs new `WMOAreaTable` rows, and **the server
  loads that DBC**, which makes it a **coupled release** (#410 5.5).
- For the pilot we accept the original area (decision 8.6), and stage 2
  measures the effects.

### 4.3 DBCs the server loads (why most map rows are client-only)

The server loads 44 DBCs (`DBCStores.cpp`). For maps, the relevant ones are
`WMOAreaTable`, `WorldMapArea` and `WorldSafeLocs`. **Not** loaded: `Map`,
`AreaTable`, `AreaTrigger` and `LoadingScreens`. The server uses SQL for those
(#410 2.3).

So the map's `Map.dbc` / `AreaTable.dbc` / `LoadingScreens.dbc` rows are
**client-only** and may ship alone. Their drift against `map_template` /
`area_template` is exactly what #410's consistency step reports. There is a
precedent for a server-side DBC row appender:
`twow-core/tools/dbc/add_worldsafelocs.py` adds graveyards 934/937/950 to
`WorldSafeLocs.dbc`.

### 4.4 Bots and dungeon-clear on a new map

- **Travel nodes** (`modules/mod-playerbots/src/playerbot/TravelNode.cpp`) [code]:
  - `loadNodeStore()` reads `ai_playerbot_travelnode*`. That is a module-owned
    world table, not an upstream schema.
  - A node stored with `linked = 0` sets `hasToGen`
    (`TravelNode.cpp:3466-3470`). On the next start `generateAll()` computes
    only the missing paths (`:3211-3230`, `TravelMgr.cpp:1863-1869`).
  - An **empty** table triggers a full regeneration (`:3478-3480`).
  - **`saveNodeStore` rewrites the whole table** from memory: `DELETE` of all
    three tables, then insert (`:3343-3375`). Seeding therefore happens **while
    mangosd is stopped**, on a tested copy first. Otherwise a running server's
    next save drops the seeds.
  - So a new map needs **seeded nodes** (entrance, bosses, exit), not a full
    rebuild. That is tool M6.
  - `generateAreaTriggerNodes` and `LoadMapTransfers` pick up
    `areatrigger_teleport` pairs. **A portal GO is not derived automatically**,
    so M6 seeds its map-transfer pair (OB-15).
- **mod-dungeon-clear**:
  - routes are computed "from the live navmesh", so without **mmaps** there is
    no clear;
  - boss-to-boss routes can be recorded (`DcRouteRecorder.cpp`,
    `tools/gen_routes.py`) into `routes/Route_<map>_<boss>.route`, and routes
    already exist for Turtle maps 816/820/822;
  - a new map therefore needs mmaps, then a recorded route set.

### 4.5 Failure mode: a client that does not know the map, and the login guard

- The server can send any client to any `map_template` ID. A client without the
  `Map.dbc` row **hangs on the loading screen**.
- The character then stays **saved on that map** and cannot log in again. That
  happened with Luigi on map 45 and was fixed by hand in the live DB [issue:
  #408, 2026-09-28].
- #410's version check only **warns**. For our own maps a warning is not enough,
  because the failure strands the character. We need two guards:
  1. **the entrance refuses** players whose known patch level is below the
     level that introduced the map. The portal script checks this.
  2. **a login guard**: a character saved on a custom map whose account's known
     patch level is unknown or too old is moved to the map's `ghost_entrance`
     before the world loads, with a `[MapGuard]` log line.

**Where the patch level comes from** (OB-15 review):

- **Timing:** the login guard decides **before** the world loads, but an addon
  runs only after entering the world. The addon can therefore only report the
  level of the **previous** session. The server stores it **per account** and
  decides the next login on that basis.
- **Channel:** in 1.12, `SendAddonMessage` has no `WHISPER` target (only
  PARTY/RAID/GUILD/BATTLEGROUND), so the addon cannot talk to the server that
  way. Two options:
  - **(a)** the TWPatch addon sends a dot command once at
    `PLAYER_ENTERING_WORLD`, e.g. `.twpatch <N>` via `SendChatMessage(…, "SAY")`.
    The server intercepts it, so it never shows in chat. This is the same path
    as BotMenu's `.bot roster`.
  - **(b)** the addon list in the auth packet (`AddonHandler.cpp`). It carries
    only names and CRCs, so the version would have to be in the addon name.
    That is awkward.
- **Recommendation: (a), failing closed.** An unknown or old level moves the
  character to `ghost_entrance`. On the first login after installing the patch,
  a character who is on the custom map is moved out once. That is intended.
- `.twpatch` must be usable by rank-0 accounts, like `.bot roster` (#209).
- OB-15 can write the addon side in TWPatch or BotMenu.
- **The released-map list is data**, not a hard-coded 45:
  - map ID plus the minimum patch level;
  - the same list M1 reports against;
  - the portal script and the login guard both read it.
- **Both guards must be deployed before any player can reach map 45 again**
  (OB-15).

**Two client facts for the install notes** (OB-15):

- The client sees only MPQ files that **existed when the game started**. A new
  or changed `patch-X` needs a **full client restart**, not `/reload`; this was
  seen with BotMenu 1.3's `BotList.lua`. Nostalgia's Play does this anyway.
- That `patch-X` overrides `patch-9` is common vanilla practice but **not yet
  verified on the owner's client**. It is a **hard gate** in #410 test N1: a
  test row in `patch-X` must override the same row from `patch-9`. Map work
  starts only after N1 passes.

## 5. Pilot path comparison

**Starting point** [issue: #408, #427]:

- the citadel content is in `tw_world`: map 45, 23 creatures, 12 GOs, 11 bosses,
  loot, and an instance script with 4 boss scripts;
- **no Turtle client has map 45**: it is missing from both clients' `Map.dbc`,
  and there is no WDT or ADT;
- twow-core#198 secures the dead entrance;
- **no instance binds exist for 45**, because nobody ever entered (OB-20).

**New context:** a Turtle wiki note relayed by OB-00 [community, not verified by
this session] says the citadel was **planned as a 40-player raid beneath the
Scarlet Monastery** and was **shelved because of problems with the instance
model**. That fits the data:

- `map_template` 45 is a 40-player raid;
- the dead portal GO stands in Tirisfal at (2781, −880, 97.6), near the
  Monastery [issue];
- no client ever got map-45 geometry.

It supports a Monastery geometry candidate.

**Geometry of the spawns:**

- The spawns sit in a compact box: x 10–421, y −157–63, z 16–36, on two levels
  (about z 16 and z 33) [code: `sql/base/tw_world_creature.sql`]. That is typical
  of a single-WMO instance in local coordinates, whose geometry Turtle never
  shipped.
- The boss and trash scripts carry **hard-coded coordinates**: sun move points,
  add spawns, and "fell below z" checks.
  - A grep for literal float triples finds 59 in the `.hpp` files:
    `boss_ardaeus` 14, `boss_daelus` 6, `boss_mariella` 4, `trashbosses` 20,
    `trashmobs` 15.
  - OB-20's hand count of real positions is **56**.
- Map 45's own coordinates do **not** carry over to any existing geometry, so
  all spawns are re-placed.

| | (a) reuse existing geometry under map 45 | (b) Turtle map 45 data server-side | (c) new terrain, Noggit 3.3.5 → 1.12 |
|---|---|---|---|
| What it is | A `Map.dbc` row for 45 (new `Directory`) plus a **WDT generated from a text spec** (`MVER` 18, `MPHD` 0x1, empty `MAIN`, `MWMO` = the path of an **existing** 1.12 WMO, `MODF` placement). The WMO itself is unchanged; the client already has every model and texture. **No Blizzard file is copied.** Copying an existing WDT is kept only as a fallback. | There is **no map-45 client or geometry data** anywhere (#408). All that exists is DB content + scripts. So (b) is **not a path of its own**. It is the **content half** of (a) or (c). | Build terrain (and maybe a WMO) in Noggit against a 3.3.5 client, MCLQ export, then our clean-up: strip `MCCV`/`MFBO`/`MTXF`, 4-bit alpha, only assets that exist in 1.12. Plus a WDT, `Map.dbc` row and minimap tiles. |
| Client files in `patch-X` | 1 generated WDT + DBC rows (`Map`; `AreaTable` optional; `LoadingScreens` reused) | – | WDT, WDL, N ADTs, minimap tiles, maybe WMOs |
| Server | `map_template` 45 exists; `area_template`, portal, extraction (after M3) | spawns and script coordinates moved to the new geometry | as (a), plus terrain `maps/` |
| Content work | place 23 + 12 spawns on the new geometry; re-point about 56 script coordinates; play every fight | reuses 11 boss scripts and loot (the valuable part) | as (a), and the rooms can be **shaped to the fights** |
| Effort | **15–22 working days + 3–5 owner sessions in game** (OB-20, table below) | included in (a)/(c) | **unknown, L–XL**: no proven tool chain; a 3.3.5 client on the host; our own ADT clean-up tool (M9) |
| Risk | Medium. The **fights were built for a room shape nobody has**; mechanics may need adapting or simplifying (a per-fight owner decision). A shared WMO keeps its original area (4.2). The map-cloning technique is documented for other versions [community: OwnedCore "Copying instances to custom ID"], and Turtle's new maps 800–822 show the client accepts new `Map.dbc` rows [issue]. | Low (the data is ours, from `sql/base`) | High: no converter proven for 3.3.5 → 1.12, and every asset reference must exist in 1.12 |
| Legal | The generated WDT and the DBC rows hold only our values and a path. The MPQ is still private, like everything in `patch-X` (#410 6). Git holds only the spec and the tools. | content is already in twow-core `sql/base` | Our own terrain, but built on Blizzard textures and models, so the same private distribution |
| Client distribution | #410 pipeline: asset `patch-X-v<N>.mpq`; map rows are client-only, so the release goes alone | – | same, larger MPQ |

**OB-20's cost estimate for path (a)** (review of this PR, 2026-09-28):

| Step | Contents | Who | Effort |
|---|---|---|---|
| 0 | Prerequisite: #409 stage 1 (`patch-X` reaches the owner + one friend; N1 load-order gate) | OB-15/OB-30 | ongoing |
| 1 | M1 inventory/consistency | OB-30 | 0.5 d |
| 2 | Extractor fix + byte-identity check, M2 DBC rows, M4 WDT generator, Stockade spike including the owner's client test, vmaps/mmaps | OB-30/OB-15 (+ owner test) | 3–4 d |
| 3a | Pick the geometry (2–3 candidates, walked in game) | OB-20 + owner | 0.5 d |
| 3b | Re-place the spawns (23 + 12, `.gps` in game) | owner in game + OB-20 migration | 1–2 d |
| 3c | Re-point about 56 script coordinates and **play through each of the 11 fights** | OB-20 + owner tests | 3–4 d |
| 3d | Generic `custom_dungeon_portal` (M7), lift #198 for 45 only | OB-20 | 1 d |
| 3e | Guard: entrance condition + login relocate (M8, `.twpatch`) | OB-20 + OB-15 | 1.5–2 d |
| 3f | Bots: M6 travel nodes, dungeon-clear routes | OB-10 | 1–2 d |
| 3g | Acceptance: full clear with a patched player + bots, exit, death/ghost_entrance, unpatched client blocked | all + owner | 1 d |
| Buffer | Bugs in unreleased encounters: untested code, and mechanics may not fit the new room shape | OB-20 | +3–5 d |

Critical path: #409 stage 1 → extractor fix → spike → 3b/3c.

**Geometry candidates for (a)** (decision 8.3):

1. **The old `Monastery` WDT** (map 44 "Old Scarlet Citadel" in the older 2025
   client on Y:, WDT only, 0 ADT [issue: OB-30]). It is **not** in the current
   2026 client's `Map.dbc`. Before it counts as a candidate, OB-30 must check two
   things on the host, read-only:
   1. which WMO path its `MWMO` names;
   2. whether that WMO exists in the **current** client's MPQs.

   If both hold, we **generate our own WDT** that names that WMO; we do not copy
   the old WDT. Given the wiki note, this may be the geometry Turtle meant to
   build on [speculation].
2. **A Scarlet Monastery wing** (map 189 is WMO-only): Graveyard, Library, Armory
   or Cathedral. This is the lore fit, and the geometry is certain to exist in
   the current client.
3. Any other WMO instance with room for 11 boss areas on two levels, as a
   fallback.

The spike (stage 2) uses Stormwind Stockade (map 34) under a test ID from
900–949, because it is small and well known. The pilot geometry is chosen after
the spike.

**Recommendation:**

- **Train 10 decides (a) or (c)** (#427).
- To make that a real choice, run the **path-(c) spike (stage 5) before train
  10 starts**. It needs host approval for a 3.3.5 client.
- If the spike shows no clean 1.12 terrain, **(a) with the Monastery** is the
  default.
- Either way, the prerequisite stages 1–2 and the guard are the same, so they
  start before train 10.

## 6. Tools we could build ourselves

### 6.1 Ground rules

**The owner's tool principle** (#409, 2026-09-28) binds every tool:

1. general rather than built for one case;
2. data-driven and repeatable;
3. tested (synthetic data, a round trip, a consistency check against server SQL);
4. documented in a README;
5. maintainable across client versions;
6. usable locally and in the cloud.

**One toolchain, not two.** #409 stage 1 is building the client toolchain
(`ops/clientpatch/`, proposed in #409):

- a CSV/YAML **delta format per DBC** with bindings;
- a WDBC reader/writer;
- `dbcdiff` → `review.csv`;
- a build script (deltas → DBC → MPQ, with version and sha256);
- a **consistency check against server SQL** that already covers
  `map_template`/`areatrigger_template`.

**Map tooling adds bindings, checks and generators to that toolchain.** It does
not build a parallel one. Map work is another DBC delta set, plus two outputs
that are not DBCs: a WDT, and the server data files.

**One map spec per map.** A versioned file (`maps/<name>.yaml` in the toolchain)
holds:

- map ID, `Directory`, instance type, name;
- WMO path and placement (later a tile list for terrain maps);
- entrance/exit positions;
- the minimum patch level.

Everything below reads it, so the client and server sides of a map cannot
diverge.

### 6.2 The tools

| # | Tool | Where | Generic because | Benefit | Effort | Order |
|---|---|---|---|---|---|---|
| **M1** | **Map consistency rules** in the #409 consistency check. For **every** map ID, a status: `ok` / `client-missing` / `data-missing` / `unreachable` / `unreleased`. Inputs: `map_template`; client `Map.dbc` (base + our deltas, with the winning archive); spawns; `game_tele`; entrances (`areatrigger_teleport` targets, portal GOs and whether their script exists); `area_template`; the released-map list (4.5); and the `DataDir` files. **`map_template` + spawns without vmaps/mmaps is an error, not a warning**, because the server runs such a map silently wrong (4.1). Also checks `areatrigger_template` vs client `AreaTrigger.dbc`. | #409 toolchain | Rules over all maps, with no ID list in code. The same run checks Turtle's maps and every future one. | One run would have found map 45 (`client-missing`), 169 (`data-missing`: mmaps) and trigger 5340. It is the acceptance check of every stage below. | S | 1 |
| **M2** | **Map DBC bindings + a "new map" delta template** for `Map`, `AreaTable`, `LoadingScreens`, `AreaTrigger`, `WMOAreaTable`, `WorldMapArea`, using the 1.12.1.5875 layouts from WoWDBDefs. The field count is checked against the base file, and the field-3/field-11 naming (2.1) is checked against a real base row. | #409 toolchain (bindings + example deltas) | A new map is one delta file per DBC; a new client version is a new binding file. | No hand-edited DBCs; each map is a reviewable delta in Git, checked by `dbcdiff`. | S | 2 |
| **M3** | **Extractor archive option + per-map extraction.** twow-core: both extractors take the full client load order (`patch-[A-Z]` after `patch-9`) or an explicit archive list, and fail with a clear error on an unknown or missing archive. twow-repo: `extract-client-data.sh` options for a **map-ID subset** and a **fresh output directory** (`data-v<date>`, `SHA256SUMS`, a manifest with tool commit, MPQ hashes and map list). | twow-core (C++, ~50 lines per tool) + twow-repo (script) | Any archive name, any map ID; one load-order definition shared with the #409 build. | Removes limit 1 (4.1), avoids hour-long full rebuilds, and covers `MoveMapGen 169`. | S–M | 2 |
| **M4** | **WDT generator** as a build step: map spec → `.wdt` in the build output, **never in Git**, recorded in the release manifest (version, sha256, base fingerprint). It fails when the named WMO is not in the base file list. **Validator** (OB-15's condition): chunk order, chunk sizes and `MPHD` flags are compared **locally** against an existing 1.12 WMO-only WDT from the owner's client (for example the `Monastery` WDT). Nothing from that comparison is stored in Git. **Copy mode** (a client WDT under a new directory) remains only a fallback. | #409 toolchain (new output type) | One spec format for every WMO-only map; terrain maps extend it with a tile list. | Path (a) without copying a Blizzard file; reproducible from Git. | S (pywowlib or warcraft-rs `wow-wdt`, or ~100 lines of Python, with a synthetic round-trip test) | 2 |
| **M5** | **Server data from the spec**: M3 extraction for the spec's map IDs into `data-v<date>`, plus a **migration draft** following twow-core conventions (`sql/database_updates/<ts>_world.sql`, idempotent): `map_template`/`area_template` rows, portal GOs + targets, `game_tele`, `ghost_entrance`, dungeon-clear roster lines. | twow-repo (script) + twow-core (migration) | Driven by the spec. | One source of truth per map. | M | 3 |
| **M6** | **Travel node seeder for any map**: take positions (entrance, bosses, exit, portal map-transfer pair) for a map ID from the DB and the spec, and write `ai_playerbot_travelnode` rows with `linked = 0` as a migration. It runs against a **copy** of the node tables, diffs before/after, and is applied only while mangosd is stopped (4.4). | twow-core module tool or twow-repo `ops/` | Input is a map ID plus DB content; no per-map code. It also works for today's instance maps without nodes. | Bots reach and path inside every new instance; the next start builds only the new paths. | M | 3 |
| **M7** | **Generic `custom_dungeon_portal` script**: target map and position come from data (`gameobject_template.data*` or a small table); it refuses maps that are not released for the player's patch level (4.5). | twow-core (C++) | One script for all 13 Turtle portals and every future map. | Server-only entrance, with no `AreaTrigger.dbc` coupling. | S–M | 3 |
| **M8** | **Login guard + `.twpatch`**: the per-account patch level from the addon's `.twpatch <N>` (rank 0 allowed); at login, a character on a map outside the released list for that level goes to `ghost_entrance`, with a `[MapGuard]` log line. Neutral default: off (twow-core config convention). | twow-core (C++) + TWPatch addon | Data-driven list, no hard-coded 45. | Automates the manual Luigi fix of 2026-09-28. | S–M | 3 |
| M9 | **ADT sanitiser / validator** for path (c): strip `MCCV`/`MFBO`/`MTXF`, convert to 4-bit alpha, report `MH2O` without `MCLQ`, and check that every referenced asset exists in the 1.12 client listfile. Per client-version profile. | #409 toolchain | Profiles per target version, not a one-off script. | The missing link between Noggit output and 1.12. | M–L | stage 5, only for path (c) |

Also, with no new tool:

- **dungeon-clear route recording** uses the existing `DcRouteRecorder` /
  `gen_routes.py`;
- **spawn placement** is done by hand in game with `.gps`. A coordinate
  transform tool is not worth it, because the new geometry does not match the
  old layout.

### 6.3 Mapping to the principle

| Principle point | How the map tools meet it |
|---|---|
| 1 General | Rules and specs over all map IDs (M1–M8); no ID or DBC hard-coded; the archive order comes from one definition (M3). |
| 2 Data-driven | Map specs and DBC deltas in Git. Outputs (WDT, DBC, MPQ, `data-v<date>`, migrations) are versioned with sha256 in the #409 manifest. |
| 3 Tested | Synthetic mini WDT/DBC round trips (M2/M4); the M3 contract test (an unchanged client gives byte-identical output); M1 is the fixed consistency step. |
| 4 Documented | Each tool gets a README section in the #409 toolchain, including "how to add a new map" and "how to add a binding". |
| 5 Across versions | Bindings per client version; the base fingerprint from #410; the extractor version is pinned to the core pin; an unknown base or layout stops with a clear error. |
| 6 Local and cloud | Everything runs in the `extractor`/toolchain containers. The cloud runs the tests on synthetic data, and the owner or OB-15 runs the real build on the host. Windows GUI tools (Noggit, WMV) are only viewers or editors, never part of the build. |

## 7. Staged plan with acceptance checks

Each stage is its own PR: tools in twow-repo, extractor and core changes in
twow-core. Every deploy needs the owner's approval.

**Prerequisite for stages 2+:** #409 stage 1 is done, meaning `patch-X`
reaches the owner and one friend, and tests T4 and **N1 (load-order gate)**
have passed.

Stages 1–2 and the guard are needed on either path and can start before train
10. Stage 5 should run **before** train 10, so the (a)/(c) decision rests on
evidence.

### Stage 1: inventory (M1) + map 169

- **Scope:**
  - M1 as consistency rules in the #409 toolchain, run read-only against the
    client (ro), the server `data/` and a disposable DB with `sql/base` +
    migrations;
  - `MoveMapGen 169` into a new `data-v<date>` (OB-30's plan).
- **Acceptance:**
  - M1 on today's data reproduces OB-30's table:
    - 45 `client-missing`;
    - 169 `data-missing` (mmaps);
    - 44/37/50/804/806/809 flagged;
    - trigger 5340 flagged;
  - after `MoveMapGen 169`, 169 is `ok`;
  - every map in the current client has a status;
  - repeated runs give identical output.

### Stage 2: extraction fix + spike (M2, M3, M4, M5)

- **Scope:**
  - the twow-core extractor PR;
  - the per-map wrapper;
  - a test map from 900–949: a generated WDT naming Stormwind Stockade's WMO
    (map 34);
  - a test `patch-X` build carrying the `Map.dbc` row + WDT;
  - the `map_template`/`area_template` migration;
  - a GM-only `game_tele`;
  - the M4 validator run against a real 1.12 WMO-only WDT;
  - OB-30's host check of the map-44 `Monastery` WDT (5).
- **Acceptance:**
  - an **unchanged** client extracted with the new extractor is byte-identical
    to today's `data/` for every existing map;
  - with the test patch, the extractor writes vmaps + mmaps for the test ID,
    and nothing else changes;
  - the M4 validator reports no structural difference from the reference WDT;
  - after a **full client restart**, the patched client loads the test map via
    `.tele`;
  - `.gps` shows the expected zone (the original Stockade area, 4.2), which is
    recorded;
  - a bot group paths inside with no straight-line fallback (mobs stand on the
    floor and have LoS);
  - map 34 itself is unchanged;
  - M1 reports the test map `ok`;
  - mangosd RAM before and after is recorded.

### Stage 3: citadel pilot on map 45 (path (a), or on (c)'s output)

- **Scope:**
  - the spec for 45 on the geometry chosen in 8.3;
  - the `Map.dbc` row for 45 in `patch-X`;
  - spawns re-placed by hand;
  - about 56 script coordinates re-pointed, with an "adapt vs simplify" owner
    decision per fight;
  - M7 (generic portal);
  - M8 (guard + `.twpatch`);
  - lifting twow-core#198 **for 45 only**, in the same release as the guard;
  - M6 nodes;
  - dungeon-clear routes.
- **Acceptance:**
  - a patched player enters through the portal, clears all 11 bosses and gets
    loot;
  - the exit works;
  - a death releases to `ghost_entrance`;
  - bots follow in, fight, and dungeon-clear runs boss to boss;
  - **an unpatched client cannot enter**;
  - a character logged out inside, whose account then reports a lower patch
    level, logs in at the entrance and is not stranded;
  - the startup log has no missing map/vmap/mmap errors for 45;
  - M1 reports 45 `ok`.

### Stage 4 (optional): own area (M4 WMO mode)

- **Scope:** new WMOID, new `AreaTable` + `WMOAreaTable` rows.
- **Coupled release:** client `patch-X` + server `WMOAreaTable.dbc` + restart,
  under one version `N` (#410 5.5).
- **Acceptance:**
  - `.gps` and the client show the new zone name inside map 45;
  - the source instance still shows its own.

### Stage 5: new-terrain spike (M9), before train 10

- **Scope:** one ADT tile built in Noggit against a 3.3.5 client, using only
  assets that exist in 1.12, run through the MCLQ export and M9. It needs
  **host approval** for a 3.3.5 client and Noggit (a portable copy, no
  installer).
- **Acceptance:**
  - the tile loads in the 1.12 client without artefacts: liquids, texture
    blending, doodads;
  - the extractors produce a `.map` and vmaps for it;
  - M1 reports it `ok`.

  The result feeds the train-10 decision between (a) and (c).

## 8. Owner decisions

**Decided** (owner, 2026-09-28, #427 and #409):

- **8.2 Map ID for the citadel: 45 stays.** Reasons:
  - it is free in every client `Map.dbc`;
  - `map_template`, the script and the spawns already key on it;
  - no instance binds exist.

  The release that gives 45 a client row also lifts twow-core#198's guard for
  45, **and it needs M7 + M8 deployed first**.
- **8.10 Our own new maps: IDs 900–949.** This keeps them under the three-digit
  file-name limit (4.1) and clear of Turtle's 800–822.
- **8.1 Path (a) or (c): decided at the start of train 10** (#427).
  Recommendation: run stage 5 before then. Default (a) if stage 5 fails.
- Client frozen at 1.18.1 (build 7272); distribution via Nostalgia (#409/#410).

**Open**, each with a recommendation:

3. **Which geometry for (a).** Recommendation:
   - the **Monastery**, given the wiki note;
   - first the map-44 `Monastery` WDT's WMO, if OB-30's host check in stage 2
     shows that it exists in the current client;
   - otherwise a Scarlet Monastery wing (map 189).

   OB-20 and the owner pick after walking 2–3 candidates in game.
4. **DBC tool for map tables.** Recommendation: **M2 bindings in the #409 delta
   format**, checked by `dbcdiff`. No Spell-Editor bindings are needed for these
   tables.
5. **Entrance type.** Recommendation: a **portal GO with the generic M7
   script**. There is no client `AreaTrigger.dbc` row, and so no trigger drift.
   Exits likewise. OB-15 and OB-20 agree.
6. **Own area/zone for the pilot.** Recommendation: **no**. Accept the source
   WMO's area in stages 2–3 and measure the effects. Stage 4 only if they
   matter.
7. **twow-core extractor change** (M3). Recommendation: **yes**, as its own
   small PR with the byte-identity check of stage 2.
8. **Guard against unpatched clients.** Recommendation: **both** the M7
   entrance check and the M8 login guard, with the patch level from `.twpatch`
   (OB-15 option (a)), failing closed. Neutral default off; switched on in the
   funserver profile together with the first custom map.
9. **Host approval for path (c)'s spike.** Recommendation: approve a portable
   3.3.5 client + Noggit in a task directory, only for the stage-5 spike.
11. **Third-party tools.** Recommendation:
    - GPL tools (Noggit, WMV) run as separate programs only;
    - tools without a licence (WDBX, Spell Editor) are local-only;
    - permissive libraries (pywowlib, StormLib, mpqcli, warcraft-rs) may be
      pinned container dependencies;
    - every Windows GUI tool on the host needs explicit approval under
      `AGENTS.md`.
12. **Who owns what.** Recommendation:
    - OB-30: M1, M3, `MoveMapGen 169`, the host check of map 44;
    - OB-15: M2, M4, the TWPatch side of M8;
    - OB-20: M5, M7, the core side of M8, content;
    - OB-10: M6 + routes.

## 9. Sources

**Our code** (`Cilverkrow/twow-core` `15fc5da`, `Cilverkrow/twow-repo` `90834ea`):

- `tools/extractor/System.cpp`, `tools/vmap_extractor/vmapextract/{vmapexport,mpq_libmpq}.cpp`,
  `tools/mmap/src/MapBuilder.cpp`, `tools/mmap/{readme,mmapSettings.txt,offmesh.txt,mmap_extract.py}`,
  `tools/dbc/add_worldsafelocs.py`;
- `src/game/Maps/{GridMap,MoveMap,PathFinder}.cpp`, `src/game/vmap/{TileAssembler,MapTree}.cpp`,
  `src/game/World.cpp`, `src/game/Database/{DBCStores.cpp,DBCStructure.h}`,
  `src/game/ObjectMgr.cpp`;
- `sql/base/tw_world_{map_template,area_template,areatrigger_template,areatrigger_teleport,creature}.sql`;
- `src/scripts/dungeons/scarlet_citadel/*`;
- `modules/mod-playerbots/src/playerbot/{TravelNode,TravelMgr}.cpp`;
- `modules/mod-dungeon-clear/` (`README.md`, `src/.../DcRouteRecorder.cpp`, `routes/`);
- twow-repo `deploy/compose/{Dockerfile.tools,extract-client-data.sh,docker-compose.yml}`,
  `ops/assets/publish-client-data.sh`, ADR-0023.

**Project discussion:**

- #408: audit PR #411, OB-30's map checks, the Luigi fix;
- #409: the owner's tool principle, the stage-1 plan, and the owner decisions of
  2026-09-28;
- #410: client patch design;
- #424: parallel draft, superseded by this PR;
- #425: OB-20 and OB-15 reviews;
- #427: train-10 goal and decisions.

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

**Community** (search excerpts only, pages blocked):

- wowdev.wiki *ADT/v18* (the MCNK offset note);
- wowmodding.net, "WoD retro porting to Classic 1.12";
- OwnedCore, "[Guide] Copying Instances to custom ID" (thread 286031);
- Turtle forum, "What map editing software does TurtleWoW use?";
- the original Noggit blog (nogg-it.blogspot.com);
- the Turtle wiki note on the citadel's history (relayed by OB-00).

**Still to verify before relying on it** (all **[K]** items):

- the per-version split of `MCCV`/`MFBO`/`MTXF`;
- 4-bit vs 8-bit alpha;
- 1.12 ignoring the `MOHD` 0x2/0x4/0x8 flags;
- that the client reports only area triggers from its own `AreaTrigger.dbc`;
- which `Map.dbc` field 3/11 naming is right.

Stage 1/2 either reads these from the owner's client or tests them. The
`patch-X` over `patch-9` order is #410's N1 gate.

## 10. Changes in revision 2

- **Tools reorganised as M1–M9 inside the #409 toolchain**, following the
  owner's tool principle (6.1, 6.3). W1–W9 of revision 1 map onto them:
  - W1 → M1;
  - W2 → M2;
  - W3 → M3;
  - W4 → M4 (now a generator; copy is only a fallback);
  - W5 → M5;
  - W6 → M6;
  - the portal script → M7;
  - the guard → M8;
  - W9 → M9;
  - W7/W8 dropped as tools.
- **WDT generated from a text spec**, validated locally against a real 1.12
  WDT (#424, OB-15).
- **Silent failure on missing map data** (4.1); M1 treats it as an error (#424,
  OB-20).
- **`MoveMapGen 169`** closes the 169 gap without a code change (4.1, stage 1).
- **`saveNodeStore` rewrites the whole table**, so node seeding happens with the
  server stopped (4.4).
- **Login guard design**:
  - per-account level from `.twpatch` (the next login decides);
  - fail closed;
  - rank 0 allowed;
  - the released-map list is data;
  - guards deployed before 45 opens (4.5, OB-15).
- **N1 load-order gate** and **full restart** notes (4.5, OB-15).
- **Decisions recorded:**
  - 45 stays;
  - 900–949;
  - (a)/(c) at the start of train 10;

  Stage 5 moves before train 10.
- **Geometry:**
  - the map-44 `Monastery` WDT's WMO is a candidate, pending OB-30's host check;
  - the Turtle wiki note on the citadel's planned Monastery location is added
    (5).
- **OB-20's cost estimate** (15–22 days + 3–5 owner sessions) and the per-fight
  "adapt vs simplify" risk (5).
- **Coordinate count** given as a grep count of 59 and OB-20's hand count of 56.
