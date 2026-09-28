# Client patch pipeline: build, distribute and version-check our client changes

Refs #409. Status: **design only**. This document changes no code, config, DBC,
SQL or client file. It adds no binaries and no Blizzard or Turtle client data.

**Inputs:**

- the "Cloud brief (OB-00, 2026-09-27)" in the body of #409;
- the owner's client file listing
  ([#409 issuecomment-5858846212](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5858846212));
- OB-00's research findings
  ([#409 issuecomment-5858920431](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5858920431));
- the owner direction of 2026-09-27
  ([#409 issuecomment-5859017022](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5859017022)).

**Goal (owner):** the owner and 2–3 friends (Radmin VPN) all run the **same
client state**, and a new client change reaches everyone with one step. Once
that works, the project can do more on the client side: talent trees (#357,
#367), new race/class combinations (#379), tooltips of changed spells, a
graphics package (#362) and addons (#360, BotMenu).

**Revision 2 (2026-09-27).** It reworks revision 1 after the owner direction:

- **Nostalgia Launcher** is the preferred distribution route. It also
  distributes our own addons, driven by catalogues.
- **WoW-Spell-Editor** is the DBC tool.
- The Turtle launcher is **a fallback only**.
- Revision 1's own PowerShell updater is demoted to a last resort
  (section 4.4).
- New fact: **Turtle WoW was shut down on 2026-05-15 after Blizzard won an
  injunction** (research comment). This changes both the risk picture
  (section 4.1) and the legal frame (section 6).

**Short answer to the owner's question:**

- The Turtle launcher cannot carry our patches, and since the shutdown it
  cannot update anything any more.
- **Nostalgia Launcher fits the job.** It is open source (Apache-2.0) and is
  configured by one JSON file with catalogues. It installs an MPQ patch as a
  sha1-pinned **asset**, DLL mods through `dlls.txt`, and addons from Git. It
  sets the realm and starts `WoW.exe`.
- There are two hard requirements:
  - **every URL must be HTTPS with a certificate the friend's PC trusts**
    (section 5.3);
  - **Turtle's `WoW.exe` must run without Turtle's launcher**. That is test T4,
    and it is the go/no-go for stage 1.

## Contents

1. [Evidence base and confidence markers](#1-evidence-base-and-confidence-markers)
2. [Client inventory: MPQs, load order, DBCs](#2-client-inventory-mpqs-load-order-dbcs)
3. [Tools and build process](#3-tools-and-build-process)
4. [Distribution options](#4-distribution-options)
5. [Recommended setup: Nostalgia Launcher](#5-recommended-setup-nostalgia-launcher)
6. [Security and legal](#6-security-and-legal)
7. [Graphics (#362)](#7-graphics-362)
8. [Staged plan with acceptance checks](#8-staged-plan-with-acceptance-checks)
9. [Open owner decisions](#9-open-owner-decisions)
10. [Sources](#10-sources)

## 1. Evidence base and confidence markers

| Marker | Meaning |
|---|---|
| **[code]** | Read from `Cilverkrow/twow-core` `main` = `33210d8` (the OB-20 review additions: `6a5ad6d`) or `twow-repo` `main` = `9616bf7`, with file and line. |
| **[nostalgia]** | Read from `Ourouk/nostalgia-launcher` at `a3b04f2` (2026-09-21), with file and line under `src/nostalgia_launcher/`. |
| **[spell-editor]** | Read from `stoneharry/WoW-Spell-Editor` at `e69ae90` (2026-08-20). |
| **[owner]** | From the owner's client listing and the research comment in #409. |
| **[community]** | Public Turtle / vanilla modding sources (section 10). The cloud session could not open the Turtle forum or wiki directly (egress blocked); these come from **search excerpts** and are not verified against the page text. |
| **[speculation]** | Reasoned, not sourced. Each one has a test in section 8. |

The cloud session had **no access to the client**. Nothing here is based on
reading client files.

## 2. Client inventory: MPQs, load order, DBCs

### 2.1 What is on disk [owner]

- `Data\`:
  - the base archives `base, dbc, fonts, interface, misc, model, sound, speech,
    terrain, texture, wmo, backup` (`.MPQ`);
  - **`patch.MPQ` (≈1.9 GB), `patch-2.MPQ`, `patch-3.mpq` … `patch-9.mpq`**
    (Turtle, up to 2 GB each). File extensions mix upper and lower case.
- Client root:
  - `turtle-wow.exe` (≈33 MB, launcher), `WoW.exe`, `twloader.dll`;
  - `dlls.txt` (currently `WoWTranslate.dll`);
  - `Optional dlls\` (SuperWoWhook, UnitXP_SP3, VfPatcher, nampower);
  - `realmlist.wtf`.
- **No `patch-<letter>` archive** exists yet, and in particular no `patch-Z`.

### 2.2 Load order and our file name

- Archives are opened in a fixed order. A file that exists in several archives
  is taken from the archive **loaded last**.
- The override is **per file**: a patch containing `DBFilesClient\Spell.dbc`
  replaces the whole `Spell.dbc`.
- The order runs `patch.MPQ`, `patch-2` … `patch-9`, then letters up to
  `patch-Z` [community; also the research comment].
- **Turtle occupies** `patch-2` … `patch-9` [owner] and uses **`patch-Z` for
  localisation** [community].
- Community mods use letters too [community, RetroCro/TurtleWoW-Mods]:
  - Reforged HD uses A, B, C, D, E, G, I, M, P, S, T;
  - others use J, W (water) and Y (fog / night sky).
- Windows treats `patch-x.mpq` and `patch-X.MPQ` as the same name. Whether the
  client sorts letters case-insensitively is not documented [speculation: yes];
  test T6 settles it.

**Proposal: `Data\patch-X.mpq`.**

- It loads after all Turtle numbers and avoids the well-known community
  letters.
- It leaves Turtle's `Z` alone. As a consequence, a **localised** client (a
  `patch-Z` with DBCs) would override our texts, so all players run the
  **English** client (decision 9.9).
- The name lives only in the asset catalogue (`dest`), so it can move later.

### 2.3 The relevant DBCs: client, server, or both

The question for every DBC is: does the server load it too? If yes, client and
server must hold **the same file**, and a change is a coupled release.

**Server facts [code]:**

- DBCs are loaded from `DataDir/dbc/` (`src/game/Database/DBCStores.cpp:203-494`).
  In compose, `DataDir = "/opt/turtle/data"`
  (`config/canonical/compose/mangosd.overlay.conf:6`), bind-mounted from the
  host (the brief's `C:\TW\ComTW\data\dbc`).
- **Spells come from SQL, not from `Spell.dbc`.** `LoadSpellsFromSql = 1` is the
  default (`src/mangosd/mangosd.conf.dist.in:681`, `src/game/World.cpp:1542`),
  so the server reads `tw_world.spell_template`
  (`src/game/Spells/SpellMgr.cpp:3614-3624`).
- **`SkillLineAbility` comes from SQL** (`sql/base/tw_world_skill_line_ability.sql`).
- **`SkillRaceClassInfo` has a server-side SQL override** (OB-20 review, verified
  at twow-core `6a5ad6d`). `skill_race_class_info_mod` overrides `RaceMask`,
  `ClassMask`, `Flags`, `MinLevel` and `SkillTierId` per DBC row; `-1` keeps the
  DBC value (`src/game/Spells/SpellMgr.cpp:2676-2733`). New race/class skill
  access (#379, the weapon talent W of #392) is therefore server-side **SQL**,
  not a server DBC change.
- **Maps and area triggers come from SQL:** `map_template` and
  `areatrigger_template` (`sql/base/tw_world_map_template.sql`,
  `sql/base/tw_world_areatrigger_template.sql`, `ObjectMgr.cpp:5200-5202`). The
  server does not load `Map.dbc` or `AreaTrigger.dbc`, so the client's copies
  can drift from the server's content unnoticed (step 2 in 3.4).
- A DBC with a wrong field count is rejected ("Wrong client version DBC
  file?", `DBCStores.cpp:175`). The Turtle 1.18.1 DBCs the server loads
  therefore have the 1.12 layout. `Spellfmt` has 173 fields
  (`src/game/Database/DBCfmt.h:64`).
- realmd accepts **every build ≥ 7272** (1.18.1) (`src/realmd/RealmList.cpp:37-47`).
  A newer client would log in with silently mismatched data.

| DBC | What the client uses it for | Server loads it? | Must match? | Stage |
|---|---|---|---|---|
| `Talent.dbc` | Talent UI: slots, rows/columns, rank spell IDs, prerequisites | **yes** (`DBCStores.cpp:326-345`, incl. `sTalentSpellPosMap` and the inspect bit sizes) | **exactly**: `CMSG_LEARN_TALENT` sends talent ID + rank, resolved in the server's copy | 2 |
| `TalentTab.dbc` | Tab names, icons, class mask | **yes** (`:340`) | exactly | 2 (probably unchanged: no 4th tree, #357) |
| `Spell.dbc` | Names, **tooltip text and its numbers** (`$s1`, `$d`, `$o1` are computed from the client's DBC), icon, **client-side prediction** (cast bar, range, cast-while-moving) | **no** (SQL) | the **numbers must mirror `spell_template`**, or tooltips lie and the client may refuse or mis-time casts | 2 |
| `SpellIcon.dbc` | Icon path per icon ID | yes (`:324`) | exactly; **reuse existing icon IDs** | 2 (ideally unchanged) |
| `SpellItemEnchantment.dbc` | Imbue and poison names/values on items | yes (`:319`) | exactly. **Rogue poison ranks I–IV for players need one enchantment per rank**; today one script (45613) serves every level band (#386 section 3.4 b). That makes it a coupled release | 2/3 |
| `SpellCastTimes`, `SpellDuration`, `SpellRange` | Index tables | yes (`:315-321`) | exactly; **reuse existing indices** | 2 (ideally unchanged) |
| `CharBaseInfo.dbc` | **Which classes a race may pick on the creation screen** | **no** | client-only | 3 |
| `CharStartOutfit.dbc` | Outfit in the creation preview | no (server: `playercreateinfo_item`) | client-only, cosmetic | 3 (optional) |
| `ChrRaces.dbc`, `ChrClasses.dbc` | Race/class definitions | yes (`:217-218`) | exactly; **no change needed** | – |
| `SkillRaceClassInfo.dbc` | Which race/class gets which skill line | yes (`:280`), **but overridable by SQL** `skill_race_class_info_mod` | server side is changed by **SQL override**, not by the server DBC. The client DBC only has to match **functionally** (same race/class masks) for skill display | 3 |
| `SkillLineAbility.dbc` | Spellbook/trainer race and class masks | no (server: SQL) | **content** must agree with `skill_line_ability` | 3 (verify) |

**Where character creation checks race/class:**

- **Client:** the glue screen offers per race only the classes in
  `CharBaseInfo.dbc` [community knowledge for 1.12; stage 3 verifies it for
  Turtle, whose `GlueXML` may carry its own tables for high elf and goblin
  [speculation]].
- **Server [code]:** `WorldSession::HandleCharCreateOpcode`
  (`src/game/Handlers/CharacterHandler.cpp:203`) checks, in order:
  1. race and class exist in `ChrRaces`/`ChrClasses` (`:251-261`);
  2. the race is not `NOT_PLAYABLE` (`:263-271`);
  3. `Player::Create` fails with `CHAR_CREATE_ERROR` when there is **no
     `playercreateinfo` row** for the pair (`Objects/Player.cpp:917-921`,
     handler `:365-371`).
- **Consequence:** the server gate is `playercreateinfo` (#379, OB-20). The
  client patch only unhides the combination. Without the patch nothing breaks.
  Bots need no patch.

### 2.4 Mismatch effects

| Mismatch | Effect | Severity |
|---|---|---|
| `Talent.dbc` client ≠ server | wrong talent learned for a clicked slot, inspect garbled | **high**: talent releases must be coupled |
| `Spell.dbc` numbers ≠ `spell_template` | wrong tooltip and cast bar; client may block moving casts of a spell the server made instant | medium |
| Client base differs from the server's extraction (other build, other Turtle MPQs) | `patch-X` shadows newer DBCs, maps/DBCs differ | high, not caught by realmd; now unlikely, see 4.1 |
| Patch missing | old tooltips, no new slots/options | low (safe fallback) |

Without our patch, the client is simply the plain Turtle 1.18.1 client. This is
the fail-closed state.

## 3. Tools and build process

### 3.0 Tooling principles (owner, 2026-09-28, binding)

The owner's rule ([#409 issuecomment-5874344129](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5874344129))
applies to every tool here and to later tool work (#412, #419 and follow-ups).
Tools must work **now and in the future** for the project, not only for one
task. The table shows how this design meets each rule; any later stage that
cannot meet one says so in its PR.

| # | Principle | How the client patch tooling meets it |
|---|---|---|
| 1 | **General, not one case.** Every DBC, class, map or data source through configuration/bindings; nothing hard-coded like "only shaman" or "only Spell.dbc". | One generic WDBC reader/writer driven by **binding files** (`bindings/<build>/<Dbc>.toml`: field names, types, localised-string blocks). Deltas, `dbcdiff`, the build and the consistency check are all binding-driven. Adding a DBC means adding a binding file, with no code change. Consistency rules are declarative too (`consistency/*.toml`: DBC field ↔ SQL column). |
| 2 | **Data-driven and repeatable.** Versioned source files in Git; build and check by script or container; output with version and hash. | Our changes are **row/field deltas** per DBC (`changes/<Dbc>/NNNN_<desc>.csv`, only our own values), applied in order. The build runs by script (container on Linux, the same Python on Windows) and writes `patch-<letter>-v<N>.mpq`, `SHA256SUMS` and a `build-info.json` (git commit, binding set, base fingerprint, tool versions). |
| 3 | **Tested.** Synthetic test data; round trip (unchanged in → unchanged out); consistency against server SQL as a fixed step. | Tests use **self-made synthetic mini DBCs** only. The round trip read → write of an unchanged file is **byte-identical**. Delta application is tested field by field. Consistency (step 2 in 3.4) is a **mandatory** build step, not an option. |
| 4 | **Documented.** README with purpose, installation, examples, limits, extension. | `README.md` with "add a new DBC binding", "add a new consistency rule", "add a delta", "support a new client build", plus limits (for example: no new DBC columns, only layouts present in the base). |
| 5 | **Maintainable across versions.** Base fingerprint, pinned tool versions, release list. A new Turtle client or a new wave must give a clear error, not break silently. | `bases/<id>.toml` lists the known client bases (build, sha256 per DBC). The build computes the fingerprint of the given base and **stops with a clear error** when it matches no known base, or when a DBC's record size or field count disagrees with its binding. Tool versions (mpqcli/StormLib, Python) are pinned; `releases.md` is the ledger. |
| 6 | **Usable locally and in the cloud.** Container where possible; Windows-only parts clearly separated and portable, without host install. | Everything except the optional Spell Editor runs in a container **and** as plain Python on Windows. The MPQ step uses a StormLib-based CLI (mpqcli ships Windows binaries). The Spell Editor is an **optional editing aid** only (3.1): the build never depends on it. |

**Bindings from the start.** Stage 1 ships 1.12 bindings, not only the tables
stage 2 needs first:

- `Talent`, `TalentTab`, `SpellItemEnchantment`, `ChrRaces`, `ChrClasses`;
- `CharBaseInfo`, `CharStartOutfit`, `SkillRaceClassInfo`, `SkillLineAbility`;
- `Spell`, `SpellIcon`, `SpellCastTimes`, `SpellDuration`, `SpellRange`;
- `Map`, `AreaTrigger`.

Each binding is **cross-checked against the core's format string** where the
server loads the table (`src/game/Database/DBCfmt.h`, for example
`TalentEntryfmt`, `TalentTabEntryfmt`, `ChrRacesEntryfmt`, `Spellfmt` with its
173 fields). Tables the server does not load are checked against WoWDBDefs for
build 1.12.1. A binding that disagrees with the real file's header (record
size, field count) is a hard error.

### 3.1 DBC editing: WoW-Spell-Editor (owner direction)

> **Update 2026-09-28 (part A of the stage-1 task):** the **source of truth
> is the row/field deltas** (3.0 row 2), not Spell-Editor SQL scripts. The
> Spell Editor stays an **optional** GUI for looking at data and drafting
> values. A value drafted there is written back as a delta; the build never
> reads its database.

**Facts [spell-editor]:**

- It supports **1.12.1**, 2.4.3 and 3.3.5. Its import/export works **DBC ↔ SQL**
  (MySQL/MariaDB or SQLite), driven by text "binding" files per DBC and version.
- **1.12 bindings shipped:** `Spell`, `SpellIcon`, `SkillLine`,
  `SkillRaceClassInfo`, `SpellCastTimes`, `SpellDuration`, `SpellRange`,
  `SpellCategory`, `SpellRadius`, visual tables and a few others
  (`Documentation/Bindings_112_vanilla/`).
- **Not shipped for 1.12:** `Talent`, `TalentTab`, `CharBaseInfo`,
  `CharStartOutfit`, `ChrRaces`, `ChrClasses`, `SpellItemEnchantment`. We would
  write these bindings ourselves, as small text files that are our own work.
  The field layouts come from WoWDBDefs and are cross-checked against the
  core's format strings (`DBCfmt.h:75-76` for `Talent`/`TalentTab`).
- **Platform:** .NET Framework **4.8**, WPF. That means **Windows only**; there
  is no container build. `HeadlessExport` (a console program in the same repo)
  exports **all bound tables from MySQL to DBC** without the GUI
  (`HeadlessExport/Program.cs`). Import is a GUI step.
- **Licence:** the repository has **no licence file** at `e69ae90`. We use the
  published binaries locally. We **do not vendor or fork its code** into our
  repos. Our binding files are ours.

**How it is used (optional aid, not part of the build; see the update note
above):**

- For drafting, base DBCs can be imported **once per client base** into a
  **dedicated database**
  (for example `twow_clientdbc`).
  - It must never be one of the upstream schemas (ADR-0024 invariant 2).
  - It lives in the compose MariaDB or in a throwaway MariaDB container whose
    port is published to the Windows host.
- Values drafted there are written back as **deltas** in `changes/<Dbc>/`
  (3.0 row 2). Tooltip numbers are taken from `tw_world.spell_template` by the
  delta's `from spell_template.<column>` reference, which only reads the
  upstream schema. The server stays the single source of truth.
- **Host rule:** the Spell Editor runs on the owner's Windows host. `AGENTS.md`
  forbids host installs and says "if a step genuinely requires something on the
  host, stop and ask". Since the tool is Windows-only, this needs the owner's
  explicit approval: a portable copy in a task directory, no installer, no PATH
  change (decision 9.7).

### 3.2 Independent check and MPQ packing

- **`dbcdiff` (ours, ≈150 lines of Python, in a container)** parses base and
  exported DBCs and writes a **field-level diff** (`review.csv`).
  - The build **fails** when anything differs that no change script declared.
  - This guards against a wrong binding layout, which the export alone would
    never notice. That matters especially for our self-written `Talent`
    binding, and for `Spell.dbc`, whose Turtle layout the server never validates.
  - Round-trip acceptance: import + export of an **unchanged** DBC is
    **field-identical** to the original. Byte identity may fail only on
    string-block ordering, which `dbcdiff` reports separately.
- **MPQ:** **mpqcli** (open source, StormLib-based CLI) packs `patch-X.mpq` in a
  container.
  - Format **v1** (vanilla), zlib compression, with `(listfile)`.
  - Ladik's MPQ Editor is for manual inspection only.
  - The exact mpqcli flags are pinned in stage 1.

### 3.3 What is in Git and what is not

The repos are **public** (section 6). Git holds **only our own work, templates
with placeholders, and hashes**:

```text
ops/clientpatch/                       (twow-repo; stage 1 implemented, see its README)
  README.md                            purpose, install, examples, limits, how to extend
  clientpatch.toml                     patch name, pinned mpqcli + command lines, base archive order
  bindings/1.12.1.5875/<Dbc>.toml      generic field layouts (3.0), generated by tools/gen_bindings.py
                                       from WoWDBDefs and cross-checked with the core's DBCfmt.h
  bases/<id>.toml                      known client bases: build + sha256 per DBC (fingerprint)
  changes/<Dbc>/NNNN_<desc>.csv        ordered row/field deltas (own values only)
  changes/code-values.md               code-side values the SQL check cannot see (3.4)
  consistency/*.toml                   declarative rules: DBC field <-> server SQL column
  sql/sources.toml                     read-only server queries (SELECT only)
  clientpatch/ (Python package)        stdlib only: wdbc, deltas, dbcdiff, base, consistency, mpq,
                                       build, extract-base, export-sql, catalog
  tests/                               synthetic mini DBCs generated in the test itself
  tools/gen_bindings.py                reproducible binding generation
  Dockerfile                           pinned Python + mpqcli/StormLib built from source
  templates/                           Nostalgia config + catalogues, placeholders only
```

**Never in Git:**

- extracted DBCs, the SQL dump of the imported base, the built MPQ;
- the real launcher config and catalogues, which contain the private host name
  (they live on the patch host);
- any client file.

### 3.4 Build pipeline

The steps run on the owner's machine, in a container or as plain Python on
Windows (3.0 row 6). The Spell Editor is not part of the build.

```text
 (1) BASE     extract DBFilesClient\*.dbc from the client's MPQs in load order
              (mpqcli, highest-priority copy wins) -> base/ + sha256 list;
              match the fingerprint against bases/*.toml and pick its binding set;
              unknown base, or header/binding mismatch -> STOP with a clear error
 (2) CONSIST. a) for every DBC the server loads: base/X.dbc == server data/dbc/X.dbc ?
                 mismatch -> STOP (client and server were extracted differently)
              b) server SQL content vs client-only DBCs (read-only queries):
                 map_template        vs Map.dbc          (every server map must exist
                                                          in the client)
                 areatrigger_template vs AreaTrigger.dbc (id, map, position)
                 skill_race_class_info_mod vs the patched SkillRaceClassInfo.dbc
                 mismatch -> REPORT, owner/OB-20 decide (lessons of #408: map 45
                 exists only on the server and the client hangs; trigger 5340 has
                 map 0 in the DB while its entrance is on map 532)
 (3) LOAD     read every DBC that has deltas through its binding (generic reader)
 (4) CHANGE   apply changes/<Dbc>/*.csv in order (row insert/update, field set);
              a delta may say "from spell_template.<column>" for a numeric field,
              which is resolved by a read-only query; code-side values come from
              changes/code-values.md (see below)
 (5) WRITE    generic writer -> out/DBFilesClient/*.dbc (string block rebuilt)
 (6) VERIFY   dbcdiff base/ vs out/ -> review.csv; undeclared difference -> STOP
 (7) PACK     mpqcli: out/ (+ sentinel texture) -> patch-X-v<N>.mpq (v1, zlib, listfile)
 (8) SERVER   changed server-loaded DBCs -> out-server/dbc/ (deploy only with owner
              approval, coupled release, section 5.5)
 (9) PUBLISH  copy the MPQ to the patch host, catalog-gen.py rewrites assets.json
              (version N, url, sha1, size), add a line to releases.md
```

- **Versioning:** `N` is an integer that only goes up. Every release has a
  label, the git commit of `changes/`, and the base fingerprint.
- **Base fingerprint:** sha256 of every base DBC, plus name, size and sha256 of
  each Turtle `patch*.mpq`.
- **Reproducibility:** the same base plus the same deltas give the same inner
  files **and the same MPQ**. Stage 1 measured this with mpqcli v0.9.9: the
  `wow-vanilla` profile writes `FILETIME` into `(attributes)`, so two builds
  differed; `--attr-flags 5` (CRC32 + MD5, no file time) makes them
  byte-identical, and a test checks it.
- **Spell report:** step 4 can also list every tooltip-relevant field where
  `spell_template` differs from the base `Spell.dbc`. The change scripts stay
  an explicit allowlist.
- **Not every changed value is in `spell_template`** (OB-20 review). The spell
  report cannot find these:
  - the **Earthen Bulwark cap** 13/27/40 % is in code
    (`src/scripts/spells/spell_shaman.cpp`, spells 58128–58130), and its tooltip
    says literally "cannot exceed 20%": a text, not a `$s` number;
  - the **rogue poison ranks** scale by caster level in the script
    (#367 O-9 a);
  - **Stormstrike +10 % per charge** is bot-only and must **not** appear in a
    player tooltip.

  Therefore `changes/code-values.md` is a **mandatory, hand-kept list** of
  values that live in code or config. Each entry has the spell ID, value,
  source (file and line at a pinned core commit) and whether it is
  player-visible. Every tooltip change script cites its entry. When a pinned
  source line changes, stage review re-checks the entry.
- **Talent rank spells reuse the phase-1 IDs** (OB-20 review). The bot auras
  **90100–90199** (shaman #357 route B, rogue #367;
  `src/game/FunserverRogueTalents.h` holds 90150–90193) exist only in
  `spell_template`, not in the client `Spell.dbc`.
  - Stage 2 makes them the `Talent.dbc` rank spells and adds `Spell.dbc` rows
    with the **same IDs** (tooltip, icon), so the server data stays unchanged.
  - **90110 is intentionally unused.**
  - Only genuinely new spells need new IDs, free in both `spell_template` and
    the base `Spell.dbc`; stage 2 measures both maxima.

## 4. Distribution options

### 4.1 (a) Turtle launcher: fallback only

**Facts:**

- **Turtle WoW was shut down on 2026-05-15** after Blizzard won an injunction
  [owner, research comment; PC Gamer, PCGamesN]. The launcher's update servers
  are therefore presumably gone. How it behaves offline is unknown
  [speculation]; test T1.
- It never had a documented custom patch source [community].
- It has a **Mods tab**: custom `.mpq` files in `Data\` are checked there and
  applied with **Apply**. That is the documented way to keep it from deleting
  them. An excerpt says the installer "automatically checks your Data folder for
  any .MPQs that aren't supposed to be there and wipes them out" [community].
- It offers a **DXVK** toggle [community].

**Assessment:**

- **Not a channel.**
- The earlier main risk, auto-updating the client to a newer public Turtle
  build, **has largely disappeared with the shutdown**. The client base is now
  frozen de facto at 1.18.1. The base check (section 5.4) stays as a cheap
  guard against a friend copying in a different client.
- It remains relevant only **if T4 fails**, that is, if Turtle's `WoW.exe` does
  not work without it. Then our patch must be enabled once in its Mods tab (T2,
  T3).

**`dlls.txt` / `twloader.dll`:**

- Turtle's client has an integrated DLL sideloader: `twloader.dll` loads what
  `dlls.txt` lists [community: Turtle team].
- A DLL is **arbitrary native code** on the friends' PCs.
- **We never ship our own DLL.** Everything we need is data (MPQ) or Lua
  (addon).
- Nostalgia manages `dlls.txt` for catalogue mods (section 5.2). Community DLLs
  (SuperWoW, nampower, UnitXP, VanillaFixes) are offered only as opt-in mods,
  pinned by URL + sha1.

### 4.2 (b) Nostalgia Launcher (owner's preferred route)

What it is, from its code at `a3b04f2` [nostalgia]:

- **Licence and form:** Apache-2.0, PySide6. A Windows **onefile exe** from its
  GitHub releases (PyInstaller). No game files, no server list, no telemetry.
- **One config file** `nostalgia_launcher.json`. The friend imports it once, from
  a file the owner sends or from an HTTPS link, and sees a summary of every host
  it will contact before accepting (`docs/developer-guide.md`, "Security Model").
  - The config points to **three catalogues**: `assets`, `mods` and `addons`.
  - It can also embed entries, and it has an optional **news feed**.
- **Assets = MPQ patches** (`services/assets.py`):
  - an entry is `{id, url, dest, version, sha1, size, essential}`;
  - the download is streamed beside the target, SHA-1 checked and
    size-enforced, then moved into place (`services/sources/direct_file.py:102-166`,
    `sources/deploy.py:118-128`);
  - an asset is "stale" by precedence: **`version` pin**, then `sha1`, then
    `size`, then an HTTP probe (`assets.py:238-280`);
  - `essential: true` assets are auto-installed when missing
    (`controllers/assets.py:225-250`).
- **Mods** (`services/mods.py`) come from a GitHub/Codeberg release,
  `direct_file`/`direct_tar` (a pinned URL with optional sha1/size) or a Git
  archive.
  - `register_dll` writes the DLL into **`dlls.txt`** (`mods.py:269-378`).
  - `type: external-launcher` can replace `WoW.exe` as the start binary
    (`mods.py:419-444`).
  - DXVK has an allowlisted `write_dxvk_conf` post-install hook
    (`sources/hooks.py`).
- **Addons** (`services/addons.py`) are installed from a **Git host**:
  `github.com`, `gitlab.com`, `gitea.com`, `codeberg.org`, plus hosts named in
  `addon_git_hosts`.
  - The pin is `ref`, a tag or commit (`sources/git_archive.py`).
  - Inside the repo archive, an addon is found only as **`<Folder>/<Folder>.toc`**
    (folder name == `.toc` stem). A single-addon repo may instead have its
    `.toc` at the root (`addons.py:375-460`).
- **Realm:** the config's `realm` is written into `realmlist.wtf` and
  `Config.wtf` (`realmList`/`patchList`).
  - A fresh `Config.wtf` is seeded **only when none exists**.
  - The realm is re-synced at Play **with the player's consent**
    (`services/tweaks.py:131-446`, `services/update/workflow.py:104-107`,
    `:650-655`).
  - Seeded defaults include `farclip 777` (`tweaks.py:174`).
- **Play** starts the first active external-launcher mod, else **`WoW.exe`**
  (`core/filesystem.py:127-144`, `controllers/update.py:414-470`). It clears the
  WDB cache after client installs.
- **Client base:**
  - incremental client updates are **torrent-only**;
  - a single HTTPS zip (`download.http.fallback`) is used only when no `WoW.exe`
    exists (`docs/developer-guide.md`, "Client Update Pipeline").

**Constraints that shape our setup:**

1. **HTTPS only, with TLS verified against the system trust store plus
   certifi** (`core/security_http.py:26-45`). Plain `http://` is rejected
   everywhere, including redirects. Our Radmin-only host therefore needs a
   certificate the friends' PCs trust (section 5.3).
2. **Catalogues refresh at most weekly** by themselves (`CATALOG_TTL = 7 days`,
   `services/catalog.py:60`). A new patch becomes visible at once only after
   **"reload catalogue"** (`controllers/assets.py:138-170`). The in-game version
   warning (section 5.4) tells the friend to do exactly that.
3. **No local backup/rollback.** Rollback means publishing the previous file
   again under the catalogue (section 5.5).
4. **Addons need a Git host.** Private repos are not supported: there is no
   token field, and the archive is fetched anonymously. BotMenu's folder
   `BotMenu-1.12` holds `BotMenu.toc`, so it **cannot** be installed straight
   from `twow-core`. Discovery would fail and fall back to unpacking the whole
   repo into one addon folder (`addons.py:639-644`). Hence a dedicated addons
   repo (section 5.2).
5. **The MPQ scanner knows only stock 1.12.1 names** (`patch`, `patch-2`, …;
   `services/mpq.py:48-66`). In the Assets panel's optional scan, Turtle's
   `patch-3` … `patch-9` show as **"Foreign / untracked"** with a Remove button.
   Removal needs a click plus confirmation and never happens automatically
   (`mpq.py:264-280`, `controllers/assets.py:83-92`). The scan runs on every
   render of the Assets panel (`ui/qt/assets_panel.py:131-134`), so the red
   list is always in view. **These files must not be removed.** An instruction
   alone is too weak, so section 5.7 adds a technical guard.
6. **`dlls.txt` entries no catalogue mod claims** (Turtle's `WoWTranslate.dll`)
   show as "Detected (not in catalog)" with a Remove button (`mods.py:292-334`).
   Removing one drops the `dlls.txt` line first and then deletes the file
   (`mods.py:301-334`). Section 5.7 covers it too.
7. **It contacts GitHub** once a day for its own updates
   (`services/self_update.py`), and the GitHub API for addon commit SHAs. It
   contacts nothing else beyond the hosts in our config.

**Pros:**

- A finished, tested, open-source tool; no updater of our own to maintain.
- sha1-pinned MPQ install; version badges; realm handling.
- Mods, addons, news and profiles, which covers LAN and Radmin.

**Cons:**

- The HTTPS requirement, and with it certificate work.
- The weekly catalogue cache.
- No local rollback.
- Addons need a public Git repo.
- A PyInstaller exe can trigger antivirus false positives.
- Turtle patches look "foreign" in the scanner.

**Effort:** about 1–2 days for stage 1: host, certificate, config, catalogues,
tests.

**Risk:** medium until T4 and the HTTPS setup are proven, low afterwards.

### 4.3 (c) Full client package from the owner

- **What:** a one-off zip of a clean client (no `WTF\`, `Cache\`, `Logs\`,
  `Screenshots\`).
- **Pros:** guarantees an identical base.
- **Cons:** many GB (to be measured) over Radmin.
- **Fit:** it becomes Nostalgia's `download.http.fallback` for a friend who has
  **no** client yet, or it is handed over directly. It is **not** a way to ship
  changes.

### 4.4 (d) Own script updater: last resort

Revision 1 designed a PowerShell updater: a manifest, sha256, backup/rollback,
plain HTTP over Radmin. It stays a documented fallback **only if** Nostalgia
fails stage 1. Examples of failure: the HTTPS setup is not workable, or the
friends' antivirus blocks the exe. It would need no certificate, because it can
use plain HTTP inside the tunnel, but we would have to write and maintain it.

### 4.5 Comparison

| | (a) Turtle launcher | (b) Nostalgia | (c) Full package | (d) Own script |
|---|---|---|---|---|
| Own patch source | no | **yes** (catalogues) | manual | yes |
| Addons/mods too | no | **yes** | manual | would need building |
| Transfer per change | – | MB | many GB | MB |
| Integrity | – | sha1 + size per asset, TLS | – | sha256 |
| Rollback | no | republish old version | old zip | local backup |
| Build effort | 0 | config + host + certificate | ≈1 h | ≈1–2 days of code |
| Main risk | offline behaviour, deletion | T4, HTTPS setup | size | maintenance |

## 5. Recommended setup: Nostalgia Launcher

**Recommendation:** **(b) Nostalgia** for every change, **(c) once** for friends
without a client, **(a) only if T4 fails**, and **(d) only if (b) fails
stage 1**.

### 5.1 Components

```text
 owner's host (Radmin)                         friend's PC
 ┌──────────────────────────────┐              ┌───────────────────────────────┐
 │ realmd / mangosd (existing)  │◄── game ─────│ WoW.exe (Turtle 1.18.1 base)  │
 │                              │              │   Data\patch-X.mpq  (asset)   │
 │ patch-host (static HTTPS,    │── HTTPS ────►│   Interface\AddOns\TWPatch …  │
 │  bound to Radmin IP only)    │              │   dlls.txt (opt-in mods)      │
 │   /nostalgia_launcher.json   │              │ NostalgiaLauncher.exe         │
 │   /catalog/assets.json       │              │   imports the config once,    │
 │   /catalog/mods.json         │              │   Play = WoW.exe              │
 │   /catalog/addons.json       │              └───────────────────────────────┘
 │   /news.json                 │                       ▲
 │   /files/patch-X-v<N>.mpq    │   github.com (public) │ addon archives by tag
 │   /client/base-1.18.1.zip    │   Cilverkrow/twow-client-addons
 └──────────────────────────────┘
```

- **Patch host:** a small static-file container (for example Caddy) in the
  compose stack.
  - It is **bound to the Radmin IP**, so nothing is published to the internet.
  - Its files live in a host directory outside Git.
  - Deploying it needs the owner's approval.

### 5.2 Config and catalogues (templates; real values only on the host)

**`nostalgia_launcher.json`:** the friend imports it once; the owner sends it as
a file.

```json
{
  "server": {
    "name": "TWOW (private)",
    "url": "https://<patch-host>",
    "realm": "<radmin-ip-of-realmd>",
    "client_version": "1.12.1",
    "news_url": "https://<patch-host>/news.json",
    "assets_registry_url": "https://<patch-host>/catalog/assets.json",
    "mods_registry_url": "https://<patch-host>/catalog/mods.json",
    "addons_registry_url": "https://<patch-host>/catalog/addons.json",
    "download": {
      "update": false,
      "http": { "fallback": "https://<patch-host>/client/base-1.18.1.zip" },
      "content": { "type": "zip" }
    }
  }
}
```

- `client_version: "1.12.1"` makes addon discovery accept `## Interface: 11200`.
- `download.update: false` switches off the torrent client check, because we
  publish no torrent. Whether the zip fallback still works with `update: false`
  for a friend without `WoW.exe` is **not verified** [speculation]; that is test
  N3. If it does not, the base is handed over directly.
- For the owner's LAN play, a second profile with a LAN `realm` can be used.
  Nostalgia supports several profiles.

**`catalog/assets.json`:** generated by `catalog-gen.py` in pipeline step 9.

```json
[
  {
    "id": "twow-patch",
    "name": "TWOW client patch",
    "description": "Talents, tooltips, character creation (v3: shaman talents)",
    "url": "https://<patch-host>/files/patch-X-v3.mpq",
    "dest": "Data/patch-X.mpq",
    "version": "3",
    "sha1": "<40 hex>",
    "size": 0,
    "essential": true
  }
]
```

- Every release gets a **new versioned file name** on the host; `dest` never
  changes. Old files stay on the host, which is what makes rollback possible.
- `essential: true` means the patch installs automatically on a fresh setup.
  Updates show as "update available" once the catalogue has been reloaded.
- Optional graphics presets (`ReShade.ini`, preset files) are further assets
  with `essential: false` (section 7).

**`catalog/addons.json`:** our own addons, from a public addons repo, **pinned
by full commit SHA** (OB-15 review). Each addon has its **own tag** for humans
and the release ledger; the catalogue carries the SHA the tag points to.

```json
[
  { "name": "TWPatch",  "git": "https://github.com/Cilverkrow/twow-client-addons",
    "ref": "<40-hex commit of tag TWPatch-v3>",
    "description": "Client patch version check (TWPatch-v3)", "recommended": true,
    "toc": { "Title": "TWPatch", "Interface": "11200" } },
  { "name": "BotMenu",  "git": "https://github.com/Cilverkrow/twow-client-addons",
    "ref": "<40-hex commit of tag BotMenu-v1.3>",
    "description": "Bot command menu (BotMenu-v1.3, core pin <sha>)", "recommended": true }
]
```

- **Why a SHA and not only a tag:**
  - a tag can be moved or re-pushed; a commit SHA cannot;
  - Nostalgia resolves a `ref` through the host API
    (`GET /repos/{owner}/{repo}/commits/{ref}`, `sources/git_archive.py:206-226`),
    which accepts a full SHA.
  - Its `git ls-remote` fallback matches only branch and tag names
    (`git_archive.py:91-119`). So if the API is rate-limited, a SHA pin cannot
    be resolved through the fallback; test N7 checks how that fails.
  - `catalog-gen.py` writes the SHA from the tag and refuses a tag that does not
    exist or moved since the ledger entry.
- **Own tags per addon** (`TWPatch-v<N>`, `BotMenu-v<x.y>`, later
  `VoiceOverVolume-v<x.y>`), never one shared tag. The addons release
  independently: TWPatch follows the patch version `N`, BotMenu follows its
  own `## Version` and the core pin.

- **New repo `Cilverkrow/twow-client-addons`** (decision 9.13):
  - layout `<Name>/<Name>.toc` per addon, so Nostalgia's discovery installs each
    addon folder separately;
  - it contains **only our own Lua/XML**, no Blizzard art;
  - releases are per-addon tags (see above);
  - BotMenu's canonical source stays in `twow-core/modules/mod-playerbots/addon/BotMenu-1.12`.
    The sync script (OB-15 review):
    - copies the **whole folder**, not a fixed file list. On `main` = `6a5ad6d`
      it holds `BotMenu.toc`, `BotMenu.xml`, `BotMenu.lua` and `README.md`
      (version 1.2); from 1.3 on, `BotList.lua` is loaded through the XML, and
      later files arrive the same way;
    - writes a **sha256 per file** into the release ledger and verifies the copy
      against the source at the pinned twow-core commit; any difference or
      missing file stops the sync;
    - takes the source from the **twow-core commit that is deployed** (the core
      pin in twow-repo), never from an unmerged branch.
  - **BotMenu is coupled to the core pin.** Its commands must match the server's
    bot command set. The `BotMenu-v<x.y>` tag and its `addons.json` entry are
    therefore published **only after** the server with that core pin is
    deployed, never before. The description records the core pin.
- **VoiceOver (#360):** the third-party addon and its 1.2 GB data pack stay a
  **manual install**, unless stage 1 shows that its repository tree has a
  Nostalgia-compatible 1.12 layout at a pinned tag. Our own adjustments (a
  separate speech volume) become an addon of ours in `twow-client-addons`.

**`catalog/mods.json`:** optional, opt-in only. Pinned `direct_file` entries
with sha1 and size, **never "latest release"**.

```json
[
  { "id": "dxvk", "type": "mod", "installation": "user_opt_in",
    "name": "DXVK (D3D9 -> Vulkan)",
    "source": { "kind": "direct_tar", "url": "https://github.com/doitsujin/dxvk/releases/download/<tag>/dxvk-<tag>.tar.gz",
                "extract_map": { "dxvk-<tag>/x32/d3d9.dll": "d3d9.dll" },
                "post_install": ["write_dxvk_conf"] },
    "installed_files": ["d3d9.dll", "dxvk.conf"] }
]
```

- The DXVK archive members are placeholders until stage 4 pins a release.
  Archive mode has no sha1 check (`direct_file.py:168-176`), so for DLLs a
  single-file `direct_file` with `sha1` is preferred where the upstream ships a
  bare DLL.

### 5.3 HTTPS for a Radmin-only host

Nostalgia refuses anything but verified HTTPS (constraint 1). Two workable ways:

1. **Own domain + Let's Encrypt via DNS-01 (recommended).**
   - A domain the owner controls (about €10 a year).
   - An `A` record such as `patch.<domain>` pointing to the host's **Radmin IP**
     (a private address; unreachable from the internet).
   - A certificate obtained through the DNS-01 challenge, which needs no inbound
     port. The DNS API token stays in the host's `.env` and **never in Git**.
   - **Pros:** publicly trusted, so friends import nothing.
   - **Cons:** a domain and a DNS token to manage. The host name becomes public
     through Certificate Transparency logs; the content does not.
2. **Own CA with name constraints.**
   - A private root CA limited (X.509 name constraints) to the one host name or
     IP. Each friend imports it once into the Windows "Trusted Root" store.
   - Python's `ssl.create_default_context()` on Windows reads the system store
     (`security_http.py:26`).
   - **Pros:** no domain.
   - **Cons:** asks friends to trust a root certificate, a real security
     decision even when name-constrained. Also, whether the frozen Nostalgia exe
     honours the Windows store as expected is **not verified** [speculation];
     that is test N2.

Rejected: plain HTTP (refused by Nostalgia), and GitHub releases for the MPQ
(it would publish Blizzard-derived files; section 6).

### 5.4 Version check against the server

There are three layers. Each works without the next.

1. **Nostalgia's own badge.** After "reload catalogue", the asset shows
   "server version changed" when its `version` differs from the installed one
   (`assets.py:260-263`).
2. **In game, no core change:**
   - the server's `Motd` is split at `@` and sent as **system messages** at
     login (`CharacterHandler.cpp:765-773` [code]);
   - the owner adds a line `[TWPatch] 3` (a config change in the funserver
     profile);
   - the **TWPatch addon** compares that line with its own version and warns:
     "Client patch v2, server expects v3: open Nostalgia → Assets → Reload →
     Update".
3. **Sentinel:** the addon shows a small texture that exists only inside
   `patch-X.mpq` (`Interface\TWPatch\sentinel-v<N>`). This proves that the MPQ is
   really loaded and has the expected version. Whether a missing texture can be
   detected reliably from Lua in 1.12 is **not verified** [speculation]; test N5
   (it is at least visible to the player). From stage 2 on, a DBC fact such as
   `GetTalentInfo` returning our new talent name adds a second check.

The **base check** (fingerprint of the Turtle MPQs) is part of the owner's build,
and it is included in the friend onboarding checklist (section 5.6).

Optional later (a twow-core PR, not stage 1):

- a login hook that sends `TWP\tEXPECT\t<n>` on the addon channel, following the
  `mod-dungeon-clear` pattern (`DungeonClearAddonHook.cpp:40-50`);
- a `[ClientPatch]` log line built from the addon list the server already
  receives at login (`AddonHandler.cpp:51-120`);
- a **BotMenu version check through the MOTD**: a line like `[BotMenu] 1.3`,
  compared by BotMenu against its own `## Version`. OB-15 takes this on as a
  follow-up (OB-15 review, point 6); it is optional and not part of stage 1.

**Strictness:** warn, never block by default (decision 9.6).

### 5.5 Releases and rollback

- **Client-only release** (a `Spell.dbc` tooltip or `CharBaseInfo` change):
  1. new MPQ `patch-X-v<N>.mpq` on the host;
  2. `assets.json` version `N`;
  3. MOTD line `[TWPatch] N`;
  4. a news item.
- **Coupled release** (`Talent`, `TalentTab`, `SpellItemEnchantment`,
  `SpellIcon` or the index tables change): the same steps **plus** the server
  DBCs from step 8 deployed to `data/dbc` and a server restart, all under the
  same `N`. Owner approval is required, as for any deploy.
- **Addon releases:**
  - TWPatch is tagged with the patch version `N`;
  - a BotMenu tag goes out only **after** the deploy of the core pin it was
    synced from (see 5.2);
  - `catalog-gen.py` writes the commit SHAs into `addons.json`.
- **SQL-side companions** ship under the same `N` as a normal twow-core
  migration, not as a server DBC:
  - `skill_race_class_info_mod` rows;
  - `spell_template` rows;
  - switching off the phase-1 aura grants (stage 2).
- **Rollback:**
  1. `catalog-gen.py --release <N-1>` points `assets.json` back to the previous
     file and version string;
  2. friends reload the catalogue and press Update;
  3. for a coupled release, the previous server DBCs go back together with it.

  Nostalgia keeps no local backup, so the host keeps **at least the last three**
  MPQ versions and the matching server DBC sets, with hashes in `releases.md`.

### 5.6 Friend onboarding (one-off, stage 1)

1. Download `NostalgiaLauncher-windows-x86_64.exe` from the **official GitHub
   release** of a version the owner names, and check its sha256 against
   `releases.md`.
2. Only if needed (section 5.3 option 2): import the owner's CA certificate.
3. Start Nostalgia, import `nostalgia_launcher.json` (file from the owner), check
   the host summary, accept.
4. Choose the game folder: the existing Turtle 1.18.1 English client, or the
   base zip. Run the base check (a small hash list script, or compare against
   the owner's listing).
5. Assets → the essential `twow-patch` installs. Addons → TWPatch (and BotMenu).
6. **Run the base guard** (section 5.7). It sets the read-only attribute on
   the Turtle files and records their hashes. **Never remove** `patch-3` …
   `patch-9` in the Assets panel's scan, or `WoWTranslate.dll` in "Detected (not
   in catalog)". They are Turtle's, and the guard makes such a click fail.
7. Play → accept the realm write → log in. The MOTD line and the TWPatch addon
   both say "up to date".

### 5.7 Base guard: Turtle's files must not be removed

Turtle's `patch.MPQ`, `patch-2.MPQ` and `patch-3` … `patch-9` are the client
base. Since the shutdown **there is no source to download them again** except
the owner's own copy. Losing one breaks the client, and the Nostalgia UI shows
them in red next to a Remove button (constraint 5). Three measures, from
cheapest to most thorough:

1. **Read-only attribute (technical guard, stage 1).** A small script
   `base-guard.ps1` (in `ops/clientpatch/`, run once during onboarding and
   again after every restore) does two things:
   - it sets the Windows read-only attribute (`attrib +R`) on
     `Data\patch.MPQ`, `Data\patch-2.MPQ`, `Data\patch-3.mpq` … `patch-9.mpq`
     and on `WoWTranslate.dll`;
   - it writes their names, sizes and sha256 to `TWPatchase.sha256`.

   **Why this works:**
   - Nostalgia removes a foreign MPQ with a plain `os.remove()` (`mpq.py:264-280`).
     On Windows that raises `PermissionError` for a read-only file, so the
     launcher reports "Could not remove …" and the file stays. This is
     [speculation] until test N6 confirms it on a friend's PC.
   - The same applies to a slip in Explorer, which asks an extra question for
     read-only files.

   **Why it does not get in the way:**
   - The client only reads its archives, so read-only MPQs still load
     [speculation, test N6].
   - Nothing is left that would legitimately rewrite them: the Turtle launcher
     cannot update any more.
   - **Our own `patch-X.mpq` stays writable**, because Nostalgia replaces it on
     every update (`deploy.py:118-128`).

   **Limit:** for `WoWTranslate.dll`, Nostalgia drops the `dlls.txt` line
   *before* it tries to delete the file (`mods.py:301-334`). The read-only
   attribute saves the DLL but not the line. The guard therefore also keeps a
   copy of the original `dlls.txt`, and the check below restores the line.
   Whether that DLL still does anything after the shutdown is open; it stays
   untouched either way.
2. **Check and restore.** `base-guard.ps1 -Check`:
   - compares the Turtle files with `TWPatchase.sha256`;
   - reports any missing or changed file;
   - restores it from the owner's base zip on the patch host (section 5.2
     `client/base-1.18.1.zip`), or from a local copy the friend keeps.

   The TWPatch addon's in-game warning also points to this check when the
   sentinel is missing (section 5.4).
3. **Upstream fix (later, optional).** A small contribution to Nostalgia: a
   config key that declares extra "stock" archive names, so `patch-3` …
   `patch-9` stop showing as foreign at all (decision 9.16).

### 5.8 Manual path for friends without Nostalgia (kept as fallback)

A friend who does not want Nostalgia, or whose PC blocks it, keeps a **manual
path** (OB-15 review, point 7). It uses the same files and the same version
`N`, so nothing is built twice:

1. For every release, `catalog-gen.py` also writes a **manual bundle**
   `twow-client-<N>.zip` on the patch host. It contains:
   - `Data/patch-X.mpq`;
   - the addon folders (`Interface/AddOns/TWPatch/`, `Interface/AddOns/BotMenu/`)
     at exactly the commits in `addons.json`;
   - `SHA256SUMS`;
   - a short `README.txt`.

   It is fetched in the browser over HTTPS inside Radmin, or handed over
   directly.
2. The friend closes the game, deletes the **old addon folders** of these
   addons (never `WTF\`), unzips the bundle into the client root, and runs
   `base-guard.ps1 -Check`. The check also verifies the bundle files against
   `SHA256SUMS`.
3. The friend sets the realm by hand in `realmlist.wtf`, as today.
4. The version check is the same as for everyone else: the MOTD line and the
   TWPatch addon (section 5.4) tell a manual player when a new bundle is due.

**Limits:**
- no update badge and no one-click rollback; rollback means unzipping the
  previous bundle, which the host keeps for the last three versions;
- opt-in mods and graphics presets are not in the bundle; they stay
  Nostalgia-only, or are installed by hand following their README.

## 6. Security and legal

- **Turtle shutdown and injunction** [owner, research comment]:
  - Turtle WoW was shut down on 2026-05-15 after Blizzard won an injunction;
  - the court order forbids passing on Turtle **client software / source
    code**, and reportedly also publishing source code or guides for emulated
    servers;
  - the order binds the Turtle parties, but it shows how the rights holder acts.

  **Consequences for us:**
  - The Turtle/Blizzard client, `patch-X.mpq` and the server DBCs go **only** to
    the named friends over Radmin. Never a public URL, a GitHub release (public
    or private), a torrent with DHT/public trackers, or a file hoster.
  - **No search for or use of leaked Turtle sources.**
  - Our patch contains **only our own changes** on top of the base. The built
    files stay private.
- **Both repos are public** (`Cilverkrow/twow-repo`, `Cilverkrow/twow-core`,
  checked 2026-09-27). Therefore:
  - Git holds only tool code, our change scripts and bindings, templates with
    placeholders, and hashes (ADR-0024 invariant 5);
  - the **real** launcher config and catalogues, which contain the patch host
    name and the Radmin IP, stay on the host;
  - whether the repos should become private in the current legal climate is an
    owner decision (9.15);
  - `twow-client-addons` would also be public, but it holds only our own addon
    code (BotMenu is already public today in twow-core).
- **No credentials** anywhere in configs, catalogues, the addon or the MPQ.
  - Access control for files is Radmin membership plus the host binding.
  - The DNS token for the certificate (section 5.3) stays in the host's `.env`.
- **Integrity:**
  - assets are pinned by **sha1 + size** over **verified TLS**;
  - addons are pinned by **tag/commit** from GitHub over TLS;
  - mods are pinned by URL + sha1 where the upstream ships a single file;
  - sha1 is weak against a determined attacker, but here it guards against
    corruption and mistakes, while TLS guards the transport. `releases.md`
    additionally records sha256.
- **Trust in the launcher itself:**
  - it is open source (Apache-2.0) and runs only the config the friend accepted;
  - the friend sees every host before accepting;
  - it never binary-patches `WoW.exe` (`docs/developer-guide.md`).
  - A PyInstaller onefile exe may trigger antivirus heuristics. Friends use only
    the official release, whose hash is recorded in `releases.md`.
- **No own DLLs** (section 4.1). Community DLLs are opt-in, pinned, and linked to
  their source.

## 7. Graphics (#362)

| Item | Realistic? | Notes, and the Nostalgia channel |
|---|---|---|
| **View distance (`farclip`)** | yes, limited | The 1.12 engine clamps it (Nostalgia seeds `farclip 777` into a fresh `Config.wtf`, `tweaks.py:174`). More needs an exe patch, and **we do not patch Turtle's `WoW.exe`**. Fog-pushback MPQ mods exist (`patch-Y`, community). |
| **ReShade** | yes | Post-processing: AO, colour grading, sharpening, depth of field. The binary comes from the official installer. **Our presets** are optional **assets** (`ReShade.ini`, `*.ini`). |
| **DXVK** | yes | D3D9 → Vulkan, often smoother frame times. An opt-in **mod** with the allowlisted `write_dxvk_conf` hook, pinned release. Turtle's launcher toggle is no longer relevant. |
| **FSR 1** | yes, as post-processing | A ReShade shader, or an external upscaler. **DLSS / FSR 2+ are not possible**: both need engine motion vectors. |
| **"Ray tracing" via ReShade** | only in name | Screen-space GI shaders trace rays **in screen space**. Off-screen geometry does not contribute, and there are edge artefacts. **Not real RT.** |
| **RTX Remix** | experiment, open outcome | It needs a D3D9 fixed-function-style renderer, an RTX GPU and a lot of per-game asset work. Whether the 1.12 renderer is captured cleanly is unknown [speculation]. Not a package; at most a private owner experiment. |
| Own renderer | no | person-years |

## 8. Staged plan with acceptance checks

Every stage is its own PR (tool code in `twow-repo`, server data in `twow-core`
where needed). Every deploy needs the owner's approval. **Train 8** is planning;
the stages below are the implementation afterwards.

### Stage 1: tooling, host, Nostalgia, empty test patch to one friend

**Scope:**

- `ops/clientpatch/`: the Dockerfile (mpqcli + Python), `dbcdiff`,
  `catalog-gen.py`, and the templates.
- The patch host: an HTTPS container bound to the Radmin IP, with the
  certificate path per decision 9.2.
- `twow-client-addons` with `TWPatch` (version, MOTD parsing, sentinel texture
  display).
- `patch-X-v1.mpq` containing **no DBC**, only the sentinel texture.
- The MOTD line `[TWPatch] 1`.

**Go/no-go tests on the owner's PC.** Record a file listing with hashes of
`Data\`, `dlls.txt`, `realmlist.wtf` and `WTF\Config.wtf` before and after each
test, and put the results in the stage-1 PR.

| Test | Action | Question answered |
|---|---|---|
| **T4** | start **Turtle's `WoW.exe` directly** (no Turtle launcher) | Does the game run? Does `twloader.dll` still read `dlls.txt`? Is `patch-X` loaded (sentinel visible)? Is `realmlist.wtf` respected? **No-go for Nostalgia's Play button if this fails**; then an external-launcher mod (for example VanillaFixes) or the Turtle launcher is the fallback. |
| T1 | open `turtle-wow.exe` with `patch-X.mpq` present (offline, Turtle is down) | Does it start at all? Does it delete, rename or ignore unknown MPQs? |
| T2/T3 | Mods tab + Apply; "verify / repair" | Needed only if T4 fails: what changes on disk; does `patch-X` survive? |
| T6 | `patch-x.mpq` in lower case | Does case matter? |
| N1 | Nostalgia imports the config, installs the essential asset, starts via Play | Is the asset sha1 checked, is `dest` right, is the realm written with consent? |
| N2 | HTTPS path per decision 9.2 on a friend's PC | Is the certificate accepted by the frozen exe? |
| N3 | a fresh folder with no `WoW.exe`, `download.update: false` | Does the zip fallback work, or is a hand-over needed? |
| N4 | bump the catalogue to v2, then reload and update; publish v1 again (rollback) | Badge, update and rollback behave as in section 5.5. |
| N5 | TWPatch addon versus the MOTD line, and the sentinel; then an addon update and an asset update through Nostalgia | Warning on mismatch, silence on match; sentinel visible. **`WTF\` is untouched by the updates**: hash listing of `WTF\Account\…\SavedVariables\` (for example `BotMenuDB`) and `WTF\Config.wtf` before and after is identical. Nostalgia's addon code replaces only folders under `Interface\AddOns` (`services/addons.py:614-660`) and seeds `Config.wtf` only when it is missing (`update/workflow.py:104-107`), so this is expected, but it is verified. |
| N7 | `addons.json` pinned by commit SHA; one run normally, one with the GitHub API unreachable | The pinned commit installs. The failure mode without the API is recorded (no silent fallback to another commit). |
| N6 | run `base-guard.ps1`, start the game, then press Remove on `patch-3.mpq` in Nostalgia's scan and on `WoWTranslate.dll` under "Detected"; then `base-guard.ps1 -Check` | The game loads read-only MPQs. Both removals fail and the files stay. The check reports the dropped `dlls.txt` line and restores it. |

**Acceptance:**

- T4 and N1–N7 pass, or their fallbacks are decided and recorded.
- `dbcdiff` round trip: the Spell Editor's import + export of **unchanged**
  base DBCs is field-identical.
- Step 2 (consistency) reports zero differences between the client base and the
  server `data/dbc`, or lists and explains them.
- One friend completes onboarding (section 5.6) and sees "up to date" in game.
- A second Update run downloads nothing.

### Stage 2: tooltips and talents, shaman + rogue

**Scope:**

- our 1.12 bindings for `Talent`/`TalentTab` (+ `SpellItemEnchantment` if
  needed);
- change scripts for tooltips:
  - numbers are joined from `spell_template` (Ghost Wolf, imbues …);
  - **code-side values** come from `changes/code-values.md` (Earthen Bulwark
    cap, poison scaling), including rewriting literal tooltip texts such as
    "cannot exceed 20%";
- change scripts for the phase-2 talent slots of #357 / #367:
  - **the rank spells are the existing bot-aura IDs 90100–90199** (90110
    unused), with new `Spell.dbc` rows for tooltip and icon (reusing existing
    icon IDs);
- **in the same release** (OB-10, O-12): switch off the SpecAura/ClassGrant
  grants of those auras for the affected talents, and adjust the premade trims.
  Otherwise bots that learn the talent **also** keep the aura and get the
  effect twice;
- **rogue poisons for players:** one `SpellItemEnchantment` per poison rank
  I–IV (coupled server + client DBC, #386 section 3.4 b). This can move to its
  own release if #386 decides so;
- the ID reservation for genuinely new spells only;
- the coupled server release (`Talent.dbc`, `SpellItemEnchantment.dbc` … to
  `data/dbc` plus a restart) and the SQL companions (grant switch-off) under
  the same `N`.

**Acceptance:**

- `review.csv` lists exactly the intended field changes.
- In game with the patch:
  - every changed tooltip shows the server's numbers, including the
    code-side values from `code-values.md`;
  - a bot with the new talent has **either** the talent spell **or** the
    phase-1 aura, never both (check the aura list on a bot before and after
    the release);
  - Ghost Wolf rank 3 shows as instant and can be cast while moving;
  - the new slots sit in the right row and column with the right rank count;
  - learning each new talent on a test character gives the right spell
    server-side (spellbook + server log);
  - inspect from a second patched client shows the right points.
- Without the patch: the old tree, and no crash.
- Rolling back client and server together (section 5.5) restores the previous
  state.

### Stage 3: race/class for players (#379)

**Prerequisite:** the server side of #379 (`playercreateinfo*`, trainers) is done
by OB-20 and approved by the owner.

**Scope:**

- the `CharBaseInfo` binding and a change script adding (3, 7) dwarf shaman and
  (5, 2) undead paladin;
- server skill access through **`skill_race_class_info_mod` SQL rows**
  (OB-20, twow-core migration), not through a server DBC;
- client side: patch `SkillRaceClassInfo.dbc` so its race/class masks match
  the override **functionally** (step 2 b reports any difference), plus a check
  of `SkillLineAbility` content against `skill_line_ability`;
- optionally `CharStartOutfit`;
- if Turtle's `GlueXML` hard-codes class lists: a glue override. Note that
  Turtle glue will not change any more after the shutdown, so the override does
  not need re-basing.

**Acceptance:**

- With the patch, both combinations can be created. The characters log in, have
  their class skills, find a trainer in their own faction, and get the #379
  rewards.
- Without the patch the options are absent and nothing else changes.

### Stage 4: graphics package (#362)

**Scope:**

- optional assets `gfx-low` / `gfx-medium` / `gfx-high` (presets);
- the DXVK mod (pinned);
- a README with performance notes.

**Acceptance:**

- Each preset installs and uninstalls cleanly through Nostalgia.
- FPS is measured per preset in one city and one open-world spot, on the
  owner's PC and one friend's PC. Measured values only.
- The README states plainly what is post-processing (section 7).

## 9. Open owner decisions

Each decision comes with a recommendation.

1. **Distribution route.** Recommendation:
   - **Nostalgia Launcher** for every change;
   - the base client once, via zip or hand-over, for friends without one;
   - the Turtle launcher only if T4 fails;
   - an own script updater only if Nostalgia fails stage 1;
   - the **manual bundle** (section 5.8) always available for a friend without
     Nostalgia.
2. **HTTPS for the patch host.** Recommendation: **an own domain with
   Let's Encrypt DNS-01**, the name pointing to the Radmin IP. Fallback: an own
   name-constrained CA imported by each friend.
3. **Our patch file name.** Recommendation: **`Data\patch-X.mpq`**.
4. **Start path.** Recommendation: **Nostalgia Play → Turtle's `WoW.exe`**,
   provided T4 passes. Otherwise an external-launcher mod (VanillaFixes), and
   only then the Turtle launcher with `patch-X` enabled in its Mods tab.
5. **Freeze the client at 1.18.1 (build 7272).** Recommendation: **yes**. It is
   de facto frozen since the shutdown. The base check stays in onboarding
   because realmd accepts any newer build.
6. **Strictness of the version check.** Recommendation: **warn**: the Nostalgia
   badge, the MOTD line and the TWPatch addon. Revisit a login block only for
   coupled talent releases.
7. **Spell Editor on the owner's Windows host (optional aid only, 3.1).**
   Recommendation: if it is used, **approve it explicitly**, as required by
   `AGENTS.md`'s host rule:
   - a portable copy in a task directory, no installer, no PATH change;
   - database `twow_clientdbc` in the compose MariaDB or in a throwaway
     container;
   - never the upstream schemas.
8. **1.12 bindings.** Recommendation: **we write our own generic binding
   files from stage 1 on** (3.0):
   - `Talent`, `TalentTab`, `SpellItemEnchantment`, `ChrRaces`, `ChrClasses`;
   - `CharBaseInfo`, `CharStartOutfit`, `SkillRaceClassInfo`, `SkillLineAbility`;
   - `Spell` and its index tables;
   - `Map`, `AreaTrigger`.

   Each is cross-checked against `DBCfmt.h` or WoWDBDefs and verified by the
   round trip.
9. **Client language.** Recommendation: **English for everyone** (Turtle's
   `patch-Z` would override our texts).
10. **`dlls.txt`.** Recommendation: **never ship our own DLL**. Community DLLs are
    opt-in Nostalgia mods, pinned by URL + sha1.
11. **Realm handling.** Recommendation: **let Nostalgia manage it** (`realm` = the
    realmd Radmin IP, written with consent at Play). The owner uses a second
    profile for LAN.
12. **Coupled releases.** Recommendation: any change to a DBC the server loads
    ships **together with** the server DBC deploy and a restart, under one
    version `N`. The server-side SQL companions ship under the same `N`:
    - `skill_race_class_info_mod`;
    - `spell_template`;
    - the switch-off of the phase-1 aura grants.

    Client-only DBCs may ship alone.
13. **Addons repo.** Recommendation: **create public `Cilverkrow/twow-client-addons`**
    with only our own addon code:
    - TWPatch;
    - a BotMenu copy, synced as a whole folder with per-file sha256 from the
      deployed core pin;
    - later our VoiceOver adjustments.

    Each addon gets its **own tags**, and `addons.json` pins **commit SHAs**. A
    BotMenu tag goes out only after the deploy of its core pin. VoiceOver
    itself stays a manual install unless its tree fits.
14. **Graphics scope.** Recommendation: **ReShade presets as assets and DXVK as
    an opt-in mod**; farclip within the engine limit. RTX Remix is not a
    package.
15. **Public repos in the current legal climate.** Recommendation: **owner to
    decide** whether `twow-repo`/`twow-core` stay public. Either way: no host
    names, IPs, real configs or client-derived files in Git.
16. **Protecting Turtle's base files.** Owner line of 2026-09-27: they **must
    not be removed**. Recommendation:
    - **stage 1:** the base guard of section 5.7 (read-only attribute, hash
      list, check and restore from the owner's base zip);
    - **later:** a small upstream contribution to Nostalgia (a config key for
      extra stock archive names), so the files stop showing as "foreign".

    Until then, the guard makes an accidental removal fail rather than relying
    on the instruction alone.

## 10. Sources

**Code read for this revision** (cloned read-only into the session scratchpad,
nothing vendored):

- Nostalgia Launcher, `Ourouk/nostalgia-launcher` @ `a3b04f2`:
  <https://github.com/Ourouk/nostalgia-launcher>. In particular:
  - `docs/developer-guide.md` and `examples/README.md`;
  - `src/nostalgia_launcher/services/{assets,mods,addons,mpq,tweaks,catalog}.py`;
  - `services/sources/{direct_file,git_archive,deploy}.py`;
  - `core/{security_http,filesystem}.py`;
  - `controllers/{assets,update}.py`.
- WoW-Spell-Editor, `stoneharry/WoW-Spell-Editor` @ `e69ae90`:
  <https://github.com/stoneharry/WoW-Spell-Editor>. In particular: `README.md`,
  `Documentation/Bindings_112_vanilla/`, `HeadlessExport/Program.cs`, and the
  `*.csproj` target frameworks.

**Public sources** (**[community]**; search excerpts only, direct access
blocked):

- Turtle WoW Wiki, *Client Mods*: <https://turtle-wow.fandom.com/wiki/Client_Mods>
- Turtle WoW Wiki, *Client Fixes and Tweaks*:
  <https://turtle-wow.fandom.com/wiki/Client_Fixes_and_Tweaks>
- Turtle forum, *How do I add a custom MPQ / patch without Twow overwriting or
  deleting it?*: <https://forum.turtle-wow.org/viewtopic.php?t=19849>
- Turtle forum, *No custom mods (mpq) on the 1.18 launcher*:
  <https://forum.turtle-wow.org/viewtopic.php?t=21764>
- Turtle forum, *My turtle wow client don't detect custom patches MPQ for HD*:
  <https://forum.turtlecraft.gg/viewtopic.php?t=19732>
- Turtle WoW team on X, the integrated DLL sideloader:
  <https://x.com/turtlewowteam/status/1906923026471338371>
- RetroCro/TurtleWoW-Mods README:
  <https://github.com/RetroCro/TurtleWoW-Mods/blob/main/README.md>
- TurtleHD patch repo (an example of a public MPQ project):
  <https://github.com/redmagejoe/TurtleHD>
- brndd/vanilla-tweaks: <https://github.com/brndd/vanilla-tweaks>
- wowdev wiki, *MPQ*: <https://wowdev.wiki/MPQ>

**Legal context** (from the research comment in #409):

- PC Gamer:
  <https://www.pcgamer.com/games/world-of-warcraft/turtle-wow-classic-server-announces-shutdown-after-blizzard-wins-injunction/>
- PCGamesN: <https://www.pcgamesn.com/world-of-warcraft/turtle-wow-cease-and-desist>

Tools named in section 3: WoW-Spell-Editor (+ HeadlessExport), mpqcli, StormLib,
Ladik's MPQ Editor, WoWDBDefs. Versions are pinned in stage 1.
