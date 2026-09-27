# Client patch pipeline: build, distribute and version-check our client changes

Refs #409. Status: **design only**. This document changes no code, config, DBC,
SQL or client file. It adds no binaries and no Blizzard or Turtle client data.

**Brief:** the "Cloud brief (OB-00, 2026-09-27)" in the body of #409, plus the
owner's local client facts in
[#409 issuecomment-5858846212](https://github.com/Cilverkrow/twow-repo/issues/409#issuecomment-5858846212)
(file listing only).

**Goal (owner):** the owner and 2–3 friends (Radmin VPN) all run the **same
client state**, and a new client change reaches everyone with one step. Once
that works, the project can do more on the client side: talent trees (#357,
#367), new race/class combinations (#379), tooltips of changed spells, a
graphics package (#362) and addons (#360, BotMenu).

**Short answer to the owner's question.** The Turtle launcher cannot be pointed
at our own patch source, and it is more likely to fight our files than to carry
them (section 4.1). Redistributing the whole client for every change is too
heavy. The recommendation is a **hybrid**: one full client package per friend,
once, to make everyone's base identical, then a **small script updater** for our
own ~MB-sized patch over Radmin (sections 4 and 5).

## Contents

1. [Evidence base and confidence markers](#1-evidence-base-and-confidence-markers)
2. [Client inventory: MPQs, load order, DBCs](#2-client-inventory-mpqs-load-order-dbcs)
3. [Tools and build process](#3-tools-and-build-process)
4. [Distribution options](#4-distribution-options)
5. [Recommendation and version check](#5-recommendation-and-version-check)
6. [Security and legal](#6-security-and-legal)
7. [Graphics (#362)](#7-graphics-362)
8. [Staged plan with acceptance checks](#8-staged-plan-with-acceptance-checks)
9. [Open owner decisions](#9-open-owner-decisions)
10. [Sources](#10-sources)

## 1. Evidence base and confidence markers

Every claim below carries one of these markers:

| Marker | Meaning |
|---|---|
| **[code]** | Read from `Cilverkrow/twow-core` at `main` = `33210d8` or `twow-repo` at `main` = `9616bf7`. File and line are given. |
| **[owner]** | From the owner's client listing in the #409 comment. |
| **[community]** | From public Turtle / vanilla modding sources (section 10). The cloud session could not open the Turtle forum or wiki directly (egress blocked); these claims come from **search-engine excerpts** of those pages and are not verified against the page text. |
| **[speculation]** | Reasoned, but not backed by a source. Each one has a test in section 8. |

The cloud session had **no access to the client**. Nothing in this document is
based on reading client files.

## 2. Client inventory: MPQs, load order, DBCs

### 2.1 What is on disk [owner]

- `Data\`: the base archives `base, dbc, fonts, interface, misc, model, sound,
  speech, terrain, texture, wmo, backup` (`.MPQ`), plus **`patch.MPQ`
  (≈1.9 GB), `patch-2.MPQ`, `patch-3.mpq` … `patch-9.mpq`** (Turtle, up to 2 GB
  each). File extensions mix upper and lower case.
- Client root: `turtle-wow.exe` (≈33 MB, launcher), `WoW.exe`, `twloader.dll`,
  `dlls.txt` (currently `WoWTranslate.dll`), `Optional dlls\` (SuperWoWhook,
  UnitXP_SP3, VfPatcher, nampower), `realmlist.wtf`.
- **No `patch-<letter>` archive** exists yet, and in particular no `patch-Z`.

### 2.2 Load order and our file name

How a 1.12 client resolves a file:

- Archives are opened in a fixed order. A file that exists in several archives
  is taken from the archive **loaded last**. The override is **per file**: a
  patch that contains `DBFilesClient\Spell.dbc` replaces the whole `Spell.dbc`,
  not single rows.
- The order runs `patch.MPQ`, `patch-2` … `patch-9`, then letters up to
  `patch-Z` [community: "The client loads the mods in order, starting with
  patch-1.mpq, ending in patch-Z.mpq"].
- **Turtle occupies** `patch-2` … `patch-9` [owner] and uses **`patch-Z`
  internally for localisation** [community: a mod "used to be called Patch-Z
  but TWoW is using that internally for language localization" and was renamed
  to Patch-Y].
- **Popular community mods** use letters too: Reforged HD uses A, B, C, D, E,
  G, I, M, P, S, T; other mods use J, W (water) and Y (fog / night sky)
  [community, RetroCro/TurtleWoW-Mods].
- Windows treats `patch-x.mpq` and `patch-X.MPQ` as the **same file name**.
  Whether the client sorts letters case-insensitively is not documented
  [speculation: yes, because it asks the file system for a fixed name per
  slot]; the stage-1 test settles it.

**Proposal: `Data\patch-X.mpq`** (upper-case letter, lower-case extension,
matching Turtle's newer files).

- It loads after all Turtle numbers, so our DBCs win over Turtle's.
- It avoids the letters of the well-known community mods.
- It loads **before** `Y` and `Z`. That is deliberate: `Z` is Turtle's own
  localisation slot and we must not claim it.
- **Consequence:** a friend with a **localised** client (a `patch-Z` that
  contains DBCs) would silently override our tooltips. The updater therefore
  warns about every `patch-Y*`/`patch-Z*` it finds (section 5.2). All players
  should run the **English** client, as the owner does (decision 9.8).
- The name lives in the manifest, not in code, so it can move later.

### 2.3 The relevant DBCs: client, server, or both

The question for every DBC is: does the server load it too? If yes, client and
server must hold **the same file**, and a change is a coupled release. If no, it
is client-only and a mismatch is at worst cosmetic.

**Server facts [code]:**

- The server loads its DBCs from `DataDir/dbc/` (`src/game/Database/DBCStores.cpp:203-494`).
  In the compose deployment `DataDir = "/opt/turtle/data"`
  (`config/canonical/compose/mangosd.overlay.conf:6`), bind-mounted from the
  host (the brief's `C:\TW\ComTW\data\dbc`).
- **Spells come from SQL, not from `Spell.dbc`.** `LoadSpellsFromSql = 1` is the
  default (`src/mangosd/mangosd.conf.dist.in:681`, `src/game/World.cpp:1542`), so
  the server reads `tw_world.spell_template` (`src/game/Spells/SpellMgr.cpp:3614-3624`).
  `Spell.dbc` is loaded only when that switch is off
  (`DBCStores.cpp:184-200`).
- **`SkillLineAbility` comes from SQL** (`sql/base/tw_world_skill_line_ability.sql`),
  not from the DBC.
- The server rejects a DBC whose field count does not match its 1.12 format
  ("Wrong client version DBC file?", `DBCStores.cpp:175`). The Turtle 1.18.1
  DBCs it loads today therefore have the 1.12 layout. `Spellfmt` has 173 fields
  (`src/game/Database/DBCfmt.h:64`), the 1.12 layout.
- realmd accepts **every build ≥ 7272** (1.18.1) as valid
  (`src/realmd/RealmList.cpp:37-47`). A friend whose client was auto-updated to
  a newer Turtle build would still log in, with **silently mismatched data**.
  This matters for section 4.1.

| DBC | What the client uses it for | Server loads it? | Must match? | Stage |
|---|---|---|---|---|
| `Talent.dbc` | Talent UI: slots, rows/columns, rank spell IDs, prerequisites | **yes** (`DBCStores.cpp:326`; builds `sTalentSpellPosMap` and the inspect bit sizes, `:329-345`) | **exactly**: `CMSG_LEARN_TALENT` sends talent ID + rank, and the server resolves them in its own copy | 2 |
| `TalentTab.dbc` | Tab names, icons, background, class mask | **yes** (`:340`, fields class mask and tab page) | exactly | 2 (probably unchanged: no 4th tree, #357) |
| `Spell.dbc` | Names, **tooltip text and the numbers in it** (`$s1`, `$d`, `$o1` are computed from the client's own DBC fields), icon, **client-side prediction**: cast bar time, range check, cast-while-moving | **no** (SQL `spell_template`) | the **numbers must mirror `spell_template`**, or tooltips lie and the client may refuse or mis-time casts | 2 |
| `SpellIcon.dbc` | Icon path per icon ID | yes (`:324`) | exactly; **reuse existing icon IDs** first | 2 (ideally unchanged) |
| `SpellItemEnchantment.dbc` | Weapon imbue names/values on the item tooltip | yes (`:319`) | exactly, only if an imbue text changes | 2 (optional) |
| `SpellCastTimes`, `SpellDuration`, `SpellRange` | Index tables used by `Spell.dbc` / `spell_template` | yes (`:315-321`) | exactly; **reuse existing indices** | 2 (ideally unchanged) |
| `CharBaseInfo.dbc` | **Which classes a race may pick on the creation screen** | **no** (not in the server's load list) | client-only | 3 |
| `CharStartOutfit.dbc` | Outfit shown in the creation preview | no (server uses `playercreateinfo_item`) | client-only, cosmetic | 3 (optional) |
| `ChrRaces.dbc`, `ChrClasses.dbc` | Race/class definitions | yes (`:217-218`) | exactly; **no change needed**, both races and both classes exist | – |
| `SkillRaceClassInfo.dbc` | Which race/class gets which skill line | yes (`:280`) | exactly; the race masks of shaman and paladin skill lines may need dwarf/undead (OB-20 to verify) | 3 |
| `SkillLineAbility.dbc` | Spellbook/trainer race and class masks | no (server: SQL table) | **content** must agree with `skill_line_ability` | 3 (verify) |
| `SkillLine.dbc` | Skill names | yes (`:279`) | unchanged | – |

**Where character creation checks race/class:**

- **Client:** the glue screen offers per race only the classes listed in
  `CharBaseInfo.dbc` [community knowledge for 1.12; stage 3 verifies it for
  Turtle]. Turtle added races (high elf, goblin), so its `GlueXML` may hold its
  own race/class tables [speculation]. If it does, stage 3 has to override a
  Turtle glue file, and that override must be rebased on every Turtle update.
- **Server [code]:** `WorldSession::HandleCharCreateOpcode`
  (`src/game/Handlers/CharacterHandler.cpp:203`) checks that race and class
  exist in `ChrRaces`/`ChrClasses` (`:251-261`) and that the race is not flagged
  `NOT_PLAYABLE` (`:263-271`). Then `Player::Create` fails with
  `CHAR_CREATE_ERROR` when there is **no `playercreateinfo` row** for the pair
  (`Objects/Player.cpp:917-921`, handler `:365-371`).
- **Consequence:** the server gate is `playercreateinfo` (#379, OB-20). The
  client patch only **unhides** the combination. A friend without the patch
  simply does not see it; nothing breaks. Bots are created server-side and need
  no patch.

### 2.4 Mismatch effects, ranked

| Mismatch | Effect | Severity |
|---|---|---|
| `Talent.dbc` client ≠ server | wrong talent learned for a clicked slot, inspect garbled, points "lost" | **high**: talent releases must be coupled |
| `Spell.dbc` numbers ≠ `spell_template` | wrong tooltip; wrong cast bar; client may block moving casts for a spell the server made instant | medium |
| Client auto-updated to a newer Turtle build | our `patch-X` shadows Turtle's newer DBCs (missing new rows); maps/DBCs differ from the server's extraction | **high**, and realmd will not stop it (see above) |
| Patch missing entirely | old tooltips, no new talent slots, no new creation options | low (safe fallback) |

The last row is why the design **fails closed**: without our patch the client is
simply the plain Turtle 1.18.1 client.

## 3. Tools and build process

### 3.1 MPQ tools

| Tool | Licence / form | Use here |
|---|---|---|
| **StormLib** (Ladislav Zezula) | open source (MIT), C library | the reference MPQ implementation under everything below |
| **mpqcli** | open source, StormLib-based **CLI** (create, add, list, extract, verify) | **build step** in the container; flags for a v1 (vanilla) archive to be pinned in stage 1 |
| **Ladik's MPQ Editor** | freeware GUI, Windows | inspection and manual checks only; not part of the build |

Archive requirements for the 1.12 client: **MPQ format v1**, zlib compression,
with `(listfile)`. We avoid newer compression types [speculation: the 1.12
reader may not handle them; v1 + zlib is the safe subset].

### 3.2 DBC tools

- **WoWDBDefs** (open source) provides field definitions per build. Our field
  names come from there, cross-checked against the core's format strings
  (`DBCfmt.h`).
- **WDBX Editor** (open source GUI) is for looking at files, not for the build.
- **Our own small Python module** (≈200–300 lines, stage 1) does the pipeline
  work. It reads and writes `WDBC` (header, fixed-size records, string block),
  applies row patches, and diffs two DBCs to CSV. It **fails closed** when the
  record size or field count differs from the schema. That matters for
  `Spell.dbc`, whose Turtle layout the server never validates (it reads SQL).
  - Acceptance: read + write of an unchanged file is **byte-identical**.
  - Strings: 1.12 stores 8 locale columns plus a flag per text field. We write
    `enUS` (index 0).

### 3.3 What is in Git and what is not

In Git (`twow-repo`, stage 1: `ops/client-patch/`):

```text
ops/client-patch/
  Dockerfile              StormLib + mpqcli + Python, pinned versions
  dbc.py                  WDBC read/write/diff (tested with self-made fixtures)
  build.py                sources -> DBC -> MPQ -> manifest
  schema/                 field names per DBC (from WoWDBDefs / DBCfmt.h)
  changes/                OUR changes only, as row patches:
    talent.csv            id, field, value, issue, note
    spell-tooltips.csv    spell id, field, value | "from:spell_template"
    charbaseinfo.csv      race, class, issue
  addon/TWPatch/          the version-check addon (section 5.2)
  updater/                twpatch.ps1 + twpatch.cmd (section 5.1)
  releases.md             ledger: version, date, sha256, base fingerprint
```

**Not in Git, ever:** extracted DBCs, the built MPQ, any client file. The
`changes/*.csv` files contain only values we authored (numbers, our tooltip
text), never whole extracted tables.

### 3.4 Build pipeline

The build runs in a **container on the owner's machine**. Rationale: the
project's tooling platform is Linux + Docker, and `AGENTS.md` forbids host
installs. CI cannot build the patch, because it has no client data; CI only
tests the tools against synthetic fixtures.

```text
 (1) BASE      extract DBFilesClient\*.dbc from the pinned client's MPQs in load
               order (mpqcli), highest-priority copy wins  ->  base/ (+ sha256 list)
 (2) CONSIST.  for every DBC the server loads: base/X.dbc == server data/dbc/X.dbc ?
               mismatch -> STOP (the server and client were extracted differently)
 (3) SPELLS    for spell IDs in changes/spell-tooltips.csv marked from:spell_template,
               read the rows from tw_world (read-only query in the compose DB)
               and map them to Spell.dbc fields; also emit a REPORT of every
               tooltip-relevant field where spell_template != base Spell.dbc
 (4) PATCH     apply changes/*.csv to copies of base DBCs -> out/DBFilesClient/
 (5) DIFF      dbc.py diff base vs out -> review.csv (goes into the PR description)
 (6) PACK      mpqcli: out/ -> patch-X.mpq (v1, zlib, listfile)
 (7) SERVER    copy the changed server-loaded DBCs (Talent, TalentTab, SkillRaceClassInfo, ...)
               -> out-server/dbc/  (deployed only with owner approval, coupled release)
 (8) MANIFEST  version, sha256 + size per file, base fingerprint, git commit,
               tool versions -> manifest.json + SHA256SUMS
```

- **Versioning:** `patch_version` is an integer that only goes up (1, 2, 3 …).
  Each release also has a label (`2026-10-xx talents-shaman`) and the git commit
  of `changes/`.
- **Reproducibility:** the same inputs must give the same inner files
  (sha256 per DBC). Whether the MPQ **container** is byte-identical depends on
  StormLib writing timestamps into `(attributes)`. Stage 1 either disables
  attributes and gets identical archives, or records that identity is measured
  per inner file.
- **Base fingerprint:** sha256 of every extracted base DBC, plus name, size and
  sha256 of each Turtle `patch*.mpq`. If Turtle's files change, the fingerprint
  changes and a rebuild is required (sections 4.1 and 5.2).
- **The Spell report in step 3** is the tool that answers "which server values
  have we already changed?" (Earthen Bulwark, Ghost Wolf, imbues …) without
  anyone listing them by hand. It will also show Turtle's own differences, so
  `changes/spell-tooltips.csv` stays an explicit allowlist.
- **New IDs:** new talent spells need IDs that are free in **both**
  `spell_template` and the client `Spell.dbc`. Stage 2 reads both maxima and
  reserves a range. No number is fixed here, because none has been measured.

## 4. Distribution options

### 4.1 (a) The Turtle launcher (`turtle-wow.exe`)

**What is known:**

- The launcher updates the client from **Turtle's** servers. No documented
  setting points it at another patch source [community: none of the launcher
  documentation found mentions one]. It is closed-source.
- It has a **Mods tab**:
  - it lists recommended mods and "any custom patches that you have
    installed";
  - a custom `.mpq` goes into `Data\`, is **checked in the tab and applied**
    with the green **Apply** button;
  - unchecking + Apply removes it again [community];
  - users have reported the tab showing "No custom patches to load" with the
    files present; one fix was unchecking the launcher's DXVK option [community].
- **Deletion:** a forum excerpt says the installer "automatically checks your
  Data folder for any .MPQs that aren't supposed to be there and wipes them
  out", and the thread is titled "How do I add a custom MPQ / patch without Twow
  overwriting or deleting it?" [community, search excerpt only]. The same thread
  says the fix is a correct name plus enabling it once in the Mods tab.
- It offers a **DXVK** toggle among its "custom mods" [community].

**What follows:**

- **As a distribution channel: no.** It cannot fetch our patch.
- **As a neighbour it is a risk,** for three reasons:
  1. It may delete or disable an MPQ it does not know. Enabling it once in the
     Mods tab seems to be the supported way to protect it [community].
  2. It **auto-updates the client to the public Turtle version**. Our server
     pins 1.18.1 data, and realmd accepts any newer build (section 2.3). A
     Turtle update on one friend's PC would desync that friend silently, and
     our `patch-X` would shadow Turtle's newer DBCs.
  3. It may rewrite `realmlist.wtf` to Turtle's realm on start [speculation].
- **Unknown, and critical:** does the Turtle client load **only** the MPQs that
  the launcher enabled? That would mean "Apply" writes a list that `WoW.exe` /
  `twloader.dll` reads. Or does it load every `patch-?` like the 1.12 client, so
  that the Mods tab is just the launcher's own bookkeeping? [speculation, both
  possible]. **Stage 1 tests T1–T5 answer this** before anything else is built.

**Pros:** nothing to build; friends already know it.
**Cons:** no own source; opaque; can delete our file; drifts the client
version.
**Effort:** 0 as a channel, but the stage-1 tests are mandatory either way.
**Risk:** high (silent desync).

**Second channel: `dlls.txt` / `twloader.dll`.** Turtle's client has an
integrated **DLL sideloader**: `twloader.dll` loads the DLLs listed in
`dlls.txt` [community: Turtle team, "our client includes an integrated
sideloader, allowing you to add custom DLLs"]. It is a real channel, and the
most dangerous one:

- A DLL runs **arbitrary native code** inside `WoW.exe` with the friend's user
  rights. A DLL we build ourselves is unsigned and would trip antivirus. If the
  owner's host or the Radmin network were compromised, it would be the perfect
  delivery path for malware to all friends.
- Everything we need (DBCs, textures, glue files, addons) is **data**, and data
  goes through the MPQ. We need no code injection.
- **Recommendation: never ship our own DLL.** Well-known community DLLs
  (SuperWoW, nampower, UnitXP, VanillaFixes) stay the friend's choice, or go as
  an optional package with a **pinned sha256 of the official release** and a
  link to the source. The updater edits `dlls.txt` only for lines it added
  itself, and never touches the owner's existing `WoWTranslate.dll` line.

### 4.2 (b) Our own mini updater

A **PowerShell script** (`twpatch.ps1` + a double-click `twpatch.cmd` wrapper),
detailed in section 5.1.

- It fetches `manifest.json` from a private source, compares sha256 values,
  downloads only what changed, verifies, backs up, installs, and can roll back.
- **Source options:**

| Source | Pros | Cons | Verdict |
|---|---|---|---|
| **HTTP on the owner's host, bound to the Radmin IP only** (a tiny static file container next to the server stack) | no credentials (Radmin membership is the access control), trivial for PowerShell, same host as the server | host must be online (it is whenever the server is) | **recommended** |
| Windows SMB share over Radmin | no extra service | guest shares are awkward on Windows 10/11, or friends need a Windows account/password (credentials) | fallback |
| Private GitHub release | reliable CDN | friends need a token (credentials in the updater); puts Blizzard-derived DBCs on GitHub | **rejected** (section 6) |

- **Pros:** small updates (MB, not GB); sha256-verified; rollback; the script is
  readable, so friends can see what it does; fully under our control.
- **Cons:** we have to build and maintain it (≈1–2 days for stage 1).
  PowerShell execution policy and Mark-of-the-Web need a wrapper (section 6).
- **Risk:** low to medium. The main risk is launcher interaction, which stage 1
  settles.

### 4.3 (c) Full client package from the owner

The owner zips his client (`7z`, including `patch-X.mpq`) and hands it over.

- **Pros:** simplest. It guarantees the identical base: same Turtle build, same
  MPQs, same `WoW.exe`. That is exactly what the base fingerprint needs.
- **Cons:** the size. The listing alone shows `patch.MPQ` ≈ 1.9 GB and
  `patch-3` … `patch-9` at up to 2 GB each [owner]. The package is many GB
  (to be measured), and Radmin relay throughput makes that hours. Doing it for
  every tooltip change is not realistic. It also carries the owner's `WTF\`
  (account name, settings) unless that is excluded explicitly.
- **Effort:** low. **Risk:** low (mind the `WTF\` exclusion).

### 4.4 Comparison

| | (a) Turtle launcher | (b) Script updater | (c) Full package |
|---|---|---|---|
| Own patch source | no | yes | yes (manual) |
| Transfer per change | – | MB | many GB |
| Identical base guaranteed | no (auto-update) | only with a base check | yes |
| Rollback | no | yes | keep the old zip |
| Build effort | 0 | ≈1–2 days (stage 1) | ≈1 hour |
| Main risk | silent desync, deletion | launcher interaction | size, `WTF\` leak |

## 5. Recommendation and version check

**Recommendation for 3–4 players: (c) once + (b) for every change.**

1. **Onboarding (c), once per friend.** The owner packs a clean client (no
   `WTF\`, no `Cache\`, no `Logs\`, no `Screenshots\`) as the frozen **base
   1.18.1**. Friends who already have a Turtle client only need the base check
   below; if it passes, they skip the download.
2. **Every change (b).** Friends double-click `twpatch.cmd`. It updates our
   files and then starts the game.
3. **(a) stays out of the loop.** Whether friends may still open the Turtle
   launcher (and whether we must protect our patch via its Mods tab) is decided
   by the stage-1 tests. The expected outcome is that **our script starts
   `WoW.exe` directly**, to freeze the client version, provided T4 shows that
   `WoW.exe` + `twloader.dll` work without the launcher. That is decision 9.3.

### 5.1 Updater behaviour (`twpatch.ps1`, PowerShell 5.1, preinstalled on Windows 10/11)

1. **Locate** the client root: the script lives there, and `WoW.exe` + `Data\`
   must exist. Abort if `WoW.exe` is running.
2. **Fetch** `http://<radmin-ip>:<port>/client/manifest.json` with a short
   timeout. If the host is unreachable, say so and offer to start the game
   anyway (the old patch keeps working).
3. **Base check.** Compare name, size and sha256 of the Turtle `Data\patch*.mpq`
   with `manifest.base`. A full hash of GB files takes time, so the result is
   cached in `TWPatch\state.json` by size + modification time. On mismatch:
   **refuse to install** and explain ("your Turtle client differs from the
   server's base: it was probably auto-updated; get the base package").
4. **Diff.** For each required file, and each optional file the player opted
   into, compare the local sha256 with the manifest.
5. **Download** changed files to `TWPatch\staging\`, then verify size and
   sha256. Any mismatch: delete staging and abort.
6. **Backup.** Move replaced files to `TWPatch\backup\v<old>\` and keep the last
   two versions.
7. **Install.** Move files into place (`Data\patch-X.mpq`,
   `Interface\AddOns\TWPatch\…`), then write `TWPatch\installed.json` (version +
   our file list).
8. **Warn.**
   - About any `Data\patch-Y*` / `patch-Z*` (they load after ours; section 2.2).
   - About a **foreign** `patch-X.mpq` whose hash we never shipped. It is backed
     up, never silently overwritten.
9. **Start** the game (`WoW.exe` or the launcher, per decision 9.3).
10. **Other modes.**
    - `-Rollback` restores the previous backup.
    - `-Uninstall` removes exactly the files listed in `installed.json`.
    - `-Status` prints the installed version, the manifest version and the base
      check.

**Manifest sketch** (contains no secrets, and may be committed as a template):

```json
{
  "patch_version": 3,
  "label": "2026-10-xx talents-shaman",
  "git_commit": "<sha>",
  "min_server_patch": 3,
  "base": { "client_build": 7272,
            "files": [ { "path": "Data/patch-9.mpq", "size": 0, "sha256": "…" } ] },
  "files": [
    { "path": "Data/patch-X.mpq", "size": 0, "sha256": "…", "required": true },
    { "path": "Interface/AddOns/TWPatch/TWPatch.toc", "size": 0, "sha256": "…", "required": true },
    { "path": "Interface/AddOns/TWPatch/TWPatch.lua", "size": 0, "sha256": "…", "required": true }
  ],
  "optional": [
    { "group": "gfx-medium", "files": [ "…" ] }
  ]
}
```

### 5.2 Version check against the server

There are three layers. Each one works without the next.

1. **Updater versus manifest (stage 1).** The manifest on the owner's host *is*
   the server-side truth. The updater compares against it before every start.
2. **In-game warning with no core change (stage 1).**
   - The server's `Motd` is split at `@` and sent as **system messages** at
     login (`CharacterHandler.cpp:765-773` [code]).
   - The owner adds a MOTD line such as `[TWPatch] 3`. That is a config change
     in the funserver profile, not code.
   - The **TWPatch addon** (Lua, `## Interface: 11200`, installed by the
     updater) holds its own version. It watches `CHAT_MSG_SYSTEM` for that line
     and, on mismatch, shows a clear warning: "Client patch v2, server expects
     v3: run twpatch.cmd".
   - The same line is visible to players without the addon.
3. **Sentinel: is the MPQ actually loaded?**
   - The addon checks something that only exists when `patch-X.mpq` is read.
   - In stage 1 that is a small texture we create ourselves
     (`Interface\TWPatch\sentinel`), shown on the addon frame.
   - From stage 2 on it is also a DBC fact, for example `GetTalentInfo` returning
     our new talent's name.
   - This catches the case "file present, but the client or launcher did not
     load it" [speculation that texture loading from our MPQ works like any
     other texture; test T6].

**Optional later (core change, twow-core PR):**

- A login hook sends `TWP\tEXPECT\t<n>` on the addon channel, following the
  existing `mod-dungeon-clear` pattern (`DungeonClearAddonHook.cpp:40-50` [code]),
  behind a config key with a neutral default.
- The server also receives every client's **addon name list** at login
  (`src/game/Handlers/AddonHandler.cpp:51-120` [code]). A log line such as
  `[ClientPatch] account=<id> TWPatch=present` would give the owner a view of
  who is up to date.
- **Not needed for stage 1.**

**Strictness.** A **warning** is the right default. A hard block at login would
lock out a friend whose updater failed, which is worse than old tooltips. The
exception is a coupled talent release (`Talent.dbc` changed). There a mismatch
causes real errors (section 2.4), so the owner may want a block later
(decision 9.6).

## 6. Security and legal

- **No redistribution to strangers.** The client, `patch-X.mpq` and the server
  DBCs contain Blizzard / Turtle derived data. They go **only** to the named
  friends over Radmin, never to a public URL, a public or private GitHub
  release, or a file hoster.
- **Git holds only our own work:** tool code, our change CSVs, the addon, the
  updater, manifest templates and the release ledger with hashes. This is
  invariant 5 of ADR-0024 ("No secrets, binaries or client data in Git").
- **No credentials** in the patch, the updater or the manifest.
  - Access control is Radmin network membership.
  - The updater never reads or writes account data. It does not touch `WTF\`,
    and it touches `realmlist.wtf` only with an explicit `-SetRealmlist` flag
    (backup first), if the owner wants that (decision 9.10).
  - The full client package (c) excludes `WTF\`.
- **Integrity.** sha256 per file, taken from the manifest. The manifest arrives
  over plain HTTP inside the Radmin tunnel. A member of the Radmin network could
  therefore swap both the manifest and the file. For 3–4 trusted friends that is
  acceptable. If it is not, the next step is signing the manifest with a
  key-pair tool (for example minisign), with the public key embedded in the
  script [not proposed for stage 1].
- **Antivirus and signatures.**
  - A **readable PowerShell script** triggers far fewer antivirus false
    positives than a packed `.exe` (PyInstaller and similar are often flagged).
    Friends can also read what it does.
  - Code-signing certificates cost money and are not worth it for four people.
  - Windows marks downloaded zips with Mark-of-the-Web. Friends run
    `Unblock-File` once, or extract with 7-Zip. The `.cmd` wrapper calls
    `powershell -NoProfile -ExecutionPolicy Bypass -File twpatch.ps1`, which
    affects only this one process, not the system policy.
- **No own DLLs** (section 4.1). Third-party DLL and graphics packages are
  pinned to the official release sha256, and the friend sees the source link.

## 7. Graphics (#362)

An honest assessment of what the 1.12 engine allows without source access:

| Item | Realistic? | Notes |
|---|---|---|
| **View distance (`farclip`)** | yes, limited | A `Config.wtf` / console CVar. The 1.12 engine clamps it (commonly cited maximum 777). Going beyond that needs an exe patch (vanilla-tweaks style), and **we do not patch Turtle's `WoW.exe`**. Fog-pushback MPQ mods exist in the community (`patch-Y`). |
| **ReShade** | yes | Post-processing: ambient occlusion, colour grading, sharpening, depth of field. Works on D3D9, or on Vulkan when combined with DXVK. Depth-based effects need depth-buffer access, which needs per-client tuning. Effort: days of preset tuning, not engineering. |
| **DXVK** | yes | D3D9 → Vulkan. It often smooths frame times on modern GPUs. **The Turtle launcher already offers a DXVK toggle** [community], so we prefer that over shipping our own copy. Watch the reported conflict with the Mods tab (section 4.1). |
| **FSR 1 upscaling** | yes, as post-processing | A ReShade shader (FSR1/CAS) or an external upscaler. Real **DLSS / FSR 2+ is not possible**: both need motion vectors from the engine. |
| **"Ray tracing" via ReShade** | only in name | Screen-space GI shaders (for example RTGI-type shaders) trace rays **in screen space**. They look good in places, but nothing off-screen contributes and there are artefacts at the edges. This is **not** real ray tracing. |
| **RTX Remix** | experiment, open outcome | It needs a D3D9 **fixed-function** style renderer, an RTX GPU, and substantial per-game asset/material work. Whether the 1.12 renderer (partly shader-based) is captured cleanly is unknown [speculation]. Not a package; at most an owner experiment on an RTX PC. |
| Own renderer | no | person-years |

**Fit into the same channel:**

- Graphics become **optional groups** in the manifest (`gfx-low`,
  `gfx-medium`, `gfx-high`).
- Our own content is only **presets**: `ReShade.ini`, preset `.ini` files and a
  `Config.wtf` snippet for `farclip` and similar.
- The ReShade / DXVK binaries themselves are either left to the friend's own
  install (ReShade installer, launcher DXVK toggle) or fetched by the updater
  from the **official release** with a pinned sha256. They are never re-hosted
  as modified binaries.
- Uninstall uses the same `installed.json` list.

## 8. Staged plan with acceptance checks

Every stage is its own PR (tool code in `twow-repo`, server data in `twow-core`
where needed). Each stage needs the owner's approval before its deploy. **Train
8** is the planning train; the stages below are the implementation afterwards.

### Stage 1: tooling + empty test patch to one friend

**Scope:**

- `ops/client-patch/`: the Docker image, `dbc.py` (read/write/diff), `build.py`
  (steps 1, 2, 6, 8 of section 3.4), the updater, and the TWPatch addon with a
  version and a sentinel texture.
- `patch-X.mpq` v1 contains **no DBC**, only the sentinel texture.
- A static-file container bound to the Radmin IP.

**Launcher tests first (on the owner's PC, before any friend).** Take a file
listing with sha256 of `Data\` + `dlls.txt` + `realmlist.wtf` before and after
each step, and record the results in the stage-1 PR.

| Test | Action | Question answered |
|---|---|---|
| T1 | put `patch-X.mpq` in `Data\`, open `turtle-wow.exe`, let it check for updates | does the launcher delete, rename or ignore an unknown MPQ? |
| T2 | enable it in the Mods tab + Apply | what does "Apply" change on disk (a list file, a rename, a config)? |
| T3 | launcher "verify / repair" | does an **enabled** `patch-X` survive? |
| T4 | start `WoW.exe` directly (no launcher) | does the game run, and does `twloader.dll` still read `dlls.txt`? Is the sentinel visible? Is `realmlist.wtf` respected? |
| T5 | start through the launcher | is the sentinel visible? Is `realmlist.wtf` changed? |
| T6 | rename to `patch-x.mpq` (lower case) | does case matter? |

**Acceptance:**

- `dbc.py` round trip is byte-identical on every DBC of the server's `data/dbc`
  (run locally, results as hashes only).
- Step 2 (consistency) reports **zero** differences between the client base and
  the server `data/dbc`, or the differences are listed and explained.
- T1–T6 are answered and decision 9.3 is taken.
- One friend runs `twpatch.cmd`:
  - it installs v1;
  - `-Status` shows v1;
  - the MOTD line matches, and the addon shows "up to date";
  - the sentinel is visible;
  - `-Rollback` and `-Uninstall` leave `Data\` byte-identical to before
    (listing + hashes).
- A second run downloads nothing (idempotent).

### Stage 2: tooltips and talents, shaman + rogue

**Scope:**

- Step 3 (spell report, a read-only DB query) and step 4 (row patches).
- `spell-tooltips.csv` for the changed spells (Earthen Bulwark, Ghost Wolf,
  imbues …).
- `talent.csv` for the phase-2 slots of #357 / #367, which reuse existing icon
  IDs.
- The ID range reservation.
- The coupled server release: `out-server/dbc/Talent.dbc` (+ `TalentTab` if
  touched) deployed to `data/dbc` with a restart, the talent spells present in
  `spell_template`, and **the same `patch_version`** on the MOTD line.

**Acceptance:**

- `review.csv` in the PR lists exactly the intended field changes and nothing
  else.
- In game, with the patch:
  - the tooltip numbers of every changed spell equal the server's values;
  - Ghost Wolf rank 3 shows instant and can be cast while moving;
  - the new talent slots show in the right row/column with the right rank
    count;
  - learning each new talent on a test character yields the right spell
    server-side (`.learn`-free check via the spellbook and the server log);
  - inspecting that character from a second patched client shows the right
    points.
- Without the patch: the talent UI shows the old tree, and nothing crashes. A
  known limitation: clicking an old slot whose position moved is documented,
  which is why talent releases are coupled.
- `-Rollback` of the client **together with** a rollback of the server DBCs
  restores the previous state.

### Stage 3: race/class for players (#379)

**Prerequisite:** the server side of #379 (`playercreateinfo*` rows, trainers)
has been done by OB-20 and approved by the owner.

**Scope:**

- `charbaseinfo.csv`: add (3, 7) dwarf shaman and (5, 2) undead paladin.
- If needed: `SkillRaceClassInfo` race masks (coupled, both sides) and a
  `SkillLineAbility` content check against `skill_line_ability`.
- Optionally `CharStartOutfit` for a proper preview.
- **If Turtle's `GlueXML` hard-codes the class lists:** a glue override, with a
  note that it must be re-based on every Turtle update.

**Acceptance:**

- With the patch, both combinations can be selected and created. The new
  character logs in, has the class skills, sees a trainer in its own faction,
  and gets the class-quest rewards at the levels #379 defines.
- Without the patch the options are absent, and nothing else changes.
- Other players' clients (patched or not) show the new characters correctly.

### Stage 4: graphics package (#362)

**Scope:**

- Optional groups `gfx-low` / `gfx-medium` / `gfx-high` in the manifest: presets
  and a `Config.wtf` snippet.
- A README with performance notes.
- DXVK via the launcher toggle, or a pinned official release.
- ReShade via its official installer, or a pinned release.

**Acceptance:**

- Each preset installs and uninstalls cleanly through the updater: `-Uninstall`
  restores the listing.
- FPS is measured in one city and one open-world spot per preset on the
  owner's PC and one friend's PC. Measured values only.
- The README states plainly what is post-processing and what is not (section 7).

## 9. Open owner decisions

Each decision comes with a recommendation.

1. **Distribution model.** Recommendation: **(c) once for the base + (b) script
   updater for every change**; the Turtle launcher is not a channel.
2. **Our patch file name.** Recommendation: **`Data\patch-X.mpq`**. It loads
   after Turtle's `2`–`9`, avoids the common community letters, and leaves
   Turtle's `Z` alone.
3. **How friends start the game.** Recommendation: **our `twpatch.cmd` starts
   `WoW.exe` directly** if T4 passes, which freezes the client at 1.18.1.
   Otherwise start the Turtle launcher with `patch-X` enabled in its Mods tab,
   and accept the drift risk plus the updater's base check as the safety net.
4. **Freeze the client version at 1.18.1 (build 7272) for all players.**
   Recommendation: **yes**. Background: realmd accepts every newer build too
   (`RealmList.cpp:37-47`), so drift would not be noticed at login. A later move
   to a newer Turtle base is a planned server + client migration, not an
   accident.
5. **Hosting of the patch files.** Recommendation: a **static HTTP container on
   the owner's host, bound to the Radmin IP only**. The fallback is an SMB
   share. A GitHub release is out.
6. **Strictness of the version check.** Recommendation: **warn** (updater +
   MOTD line + addon). Revisit a hard login block only for coupled talent
   releases, after stage 2.
7. **Where the build runs.** Recommendation: **in a Docker container on the
   owner's machine**, with tool code in `twow-repo/ops/client-patch/`. CI tests
   the tools with synthetic DBCs only.
8. **Client language.** Recommendation: **all players run the English client**
   (no Turtle `patch-Z` localisation archive), because `Z` would override our
   texts.
9. **The `dlls.txt` channel.** Recommendation: **never ship our own DLL**.
   Community DLLs stay optional, pinned to the official release hash; the
   updater keeps its hands off lines it did not add.
10. **Should the updater manage `realmlist.wtf`** (LAN/Radmin switch)?
    Recommendation: **yes, but only with an explicit flag** and a backup, never
    by default.
11. **Coupled releases.** Recommendation: any change to a DBC the server loads
    (`Talent`, `TalentTab`, `SkillRaceClassInfo`, `SpellIcon`, the
    `Spell*`/`SpellItemEnchantment` index tables) ships **together with** the
    server DBC deploy and restart, under one `patch_version`. Client-only
    changes (`Spell.dbc` text/numbers, `CharBaseInfo`, `CharStartOutfit`) may
    ship alone.
12. **Addons (BotMenu, VoiceOver).** Recommendation:
    - **BotMenu** goes through the same channel as an optional group, built from
      its source in `twow-core/modules/mod-playerbots/addon/BotMenu-1.12`.
    - **VoiceOver** (third-party, 1.2 GB data pack) stays a manual install. At
      most, the updater checks for the known 1.12 release hash from #360 and
      gives a link; it never re-hosts it.
13. **Graphics scope.** Recommendation: **presets for ReShade + farclip + the
    launcher's DXVK**. RTX Remix is not a package; at most the owner can try it
    as a private experiment.

## 10. Sources

Public sources used for the **[community]** markers. The cloud session saw them
only as search-engine excerpts, because direct access was blocked by the
session's network policy. They should be re-read by the owner or OB-15 before
stage 1.

- Turtle WoW Wiki, *Client Mods*: <https://turtle-wow.fandom.com/wiki/Client_Mods>
  (load order patch-1 … patch-Z, "avoid using numbers and early letters", Mods
  tab + Apply)
- Turtle WoW Wiki, *Client Fixes and Tweaks*:
  <https://turtle-wow.fandom.com/wiki/Client_Fixes_and_Tweaks>
- Turtle forum, *How do I add a custom MPQ / patch without Twow overwriting or
  deleting it?*: <https://forum.turtle-wow.org/viewtopic.php?t=19849> (installer
  wipes unknown MPQs; patch-Z is localisation; enable once in the Mods tab)
- Turtle forum, *No custom mods (mpq) on the 1.18 launcher*:
  <https://forum.turtle-wow.org/viewtopic.php?t=21764>
- Turtle forum, *My turtle wow client don't detect custom patches MPQ for HD*:
  <https://forum.turtlecraft.gg/viewtopic.php?t=19732> (DXVK toggle conflict)
- Turtle forum, *Reorder Patch*: <https://forum.turtle-wow.org/viewtopic.php?t=17740>
- Turtle WoW team on X, integrated DLL sideloader and `dlls.txt`:
  <https://x.com/turtlewowteam/status/1906923026471338371>
- RetroCro/TurtleWoW-Mods README (letters used by community mods, `dlls.txt`):
  <https://github.com/RetroCro/TurtleWoW-Mods/blob/main/README.md>
- wowdev wiki, *MPQ*: <https://wowdev.wiki/MPQ>
- brndd/vanilla-tweaks (exe patch for farclip etc., not proposed for Turtle's
  exe): <https://github.com/brndd/vanilla-tweaks>

Tools named in section 3: StormLib (Ladislav Zezula), mpqcli, Ladik's MPQ
Editor, WoWDBDefs, WDBX Editor. Versions are pinned in stage 1, not here.
