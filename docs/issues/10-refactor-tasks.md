# Refactor tasks (OT-025)

The work of the restructuring itself. Phases 0–1 are largely done on
`refactor/modular-platform`; Phases 2–3 are open.

Full plan and reasoning: `docs/issues/00-refactor-plan.md`.

---
id: REF-001
title: Wire both C++ test suites into CTest and make them cross-platform
workstream: WS-50
priority: p0
existing_ot: OT-021
source: docs/issues/00-refactor-plan.md
superseded_by: none
body: |
  **Problem: the repo has 196 test assertions and runs none of them.**

  There is no `enable_testing()`, no `add_test()`, no CTest registration anywhere. Two
  suites exist and neither runs from a plain build:

  **1. `modules/mod-dungeon-clear/t/` — 54 gtest files (~900 KB).** Cannot build:
  - googletest is never fetched by any CMakeLists
  - `src/test/mocks/TestMap.cpp` does not exist
  - the `game-interface` target it links does not exist

  **2. `src/modules/PlayerBots/tests/` — added by `3c2b931`.**
  - `persistent_active_roster_database_tests` (48 assertions + a real multi-threaded
    concurrency scenario) IS in the main build, behind
    `BUILD_PERSISTENT_ROSTER_ADAPTER_TESTS`, default OFF. Needs a real MariaDB.
  - `persistent_active_roster_tests` (7 functions, **142 assertions**) is NOT wired in at
    all: standalone `project()`, no `add_subdirectory`, hard-requires
    `ROSTER_TEST_OPENSSL_LIBRARY` as an existing import library, unconditionally adds
    `dep/windows/include` (which shadows system OpenSSL on Linux), driven by
    `run-tests.ps1` with a hardcoded CMake path and the VS 2022 generator.
  - Neither uses a test framework — both are hand-rolled `CHECK` macros counting failures.

  **Do:**
  1. `enable_testing()` / `include(CTest)` at root.
  2. `FetchContent` googletest, pinned by tag.
  3. Create the missing `TestMap.cpp` mock and `game-interface` target.
  4. `add_subdirectory(tests)` behind `BUILD_PERSISTENT_ROSTER_UNIT_TESTS`; drop the
     standalone `project()`.
  5. Replace `ROSTER_TEST_OPENSSL_LIBRARY` with `find_package(OpenSSL REQUIRED)` +
     `OpenSSL::Crypto`.
  6. **Guard the `dep/windows/include` include dir** — unconditional, it breaks Linux.
  7. Register everything with `add_test()`; register the adapter test only when a
     connection string is supplied.

  **Success:** `ctest` runs both suites on Linux and Windows.

  **Constraint:** `3c2b931` is the tested OT-001 baseline (TODOS.md guardrail, FG-072).
  Wiring and portability changes only — do not alter test behaviour.

  **See also:** ADR-0022.
---
id: REF-002
title: Fix platform-divergent canonical-request validation in the roster
workstream: WS-10
priority: p1
existing_ot: none
source: src/modules/PlayerBots/playerbot/PersistentActiveRoster.cpp
superseded_by: none
body: |
  **Bug: the same roster admin request is accepted on Linux and rejected on Windows.**

  `PersistentActiveRoster.cpp:135-155` validates canonical request text differently per
  platform:
  - **Windows:** UTF-8 well-formedness **plus NFC normalization** (`IsNormalizedString`)
  - **POSIX `#else`:** UTF-8 well-formedness only

  So a non-NFC actor or reason string passes on Linux and fails on Windows.

  **Why it matters:** the entire roster contract is built on canonical bytes and SHA-256
  digests. Two platforms disagreeing on what "canonical" means undermines the guarantee,
  and Linux is becoming the deployment platform (ADR-0028) while the tested evidence was
  produced on Windows.

  **Do:** use one shared normalization implementation for both platforms. Add a test case
  with non-NFC input to the roster unit suite so the divergence cannot return.

  **Note:** the other two `_WIN32` guards in that file (the `windows.h` include block and
  the reparse-point check at `:249`) are fine — the POSIX branches are equivalent.
---
id: REF-003
title: Split upstream and project code into twow-core plus a submodule
workstream: WS-10
priority: p0
existing_ot: OT-016
source: docs/adr/ADR-0020-two-repo-upstream-split.md
superseded_by: none
body: |
  **Goal: make upstream merges routine and let our bug fixes go home.**

  **Today:** 114 core files differ from upstream tip `db5fb2a` (+5,246 / −1,809),
  concentrated in the files that change most often upstream — `Player.*`, `World.*`,
  `Unit.*`, `WorldSession.cpp`, `CharacterHandler.cpp`. Every merge is a hand fight, and
  our genuinely upstream-worthy fixes cannot be offered in that shape.

  **Steps:**
  1. Create `twow-core` as a **fresh clone** of `Shyalya/tortoise-wow` with a real
     `upstream` remote (this repo's history was rewritten to strip binaries, so it cannot
     share history with upstream — FG-006 forbids rewriting again).
  2. Re-apply the core delta as **small single-purpose commits**, each classified as
     either an upstream-worthy fix or an integration hook.
  3. **Upstream-worthy fixes first**, so they can be offered immediately: restored
     `BattleGroundQueue` mutex, null anticheat pointer on bot sessions, the
     `Unit::DealDamage` branch, the inverted `Engine::Init` flag, the `vfprintf`
     format-string abort, the dangling `ownerAura` in Healing Touch. Also
     `Database::DirectTransaction` + `SqlConnection::AffectedRows` from `3c2b931` — 47
     additive lines, genuinely general-purpose.
  4. Feature code spliced into upstream files is **not** re-applied — it becomes modules
     (REF-004).
  5. Add `core/` as a submodule plus `UPSTREAM.lock` (pinned SHA, upstream URL,
     merge-base). Generate `core-patches/` in CI so the review artifact cannot drift.
  6. Move `sql/base`, `sql/database_updates`, `sql/create_databases.sql` to `twow-core` —
     they are upstream's content (188 MiB, 336 files, 9 commits ever, all upstream
     authors). Fix `setup_databases.sh` there to import `sql/base` and recurse.

  **Prep that parallelizes:** classifying the 114-file delta into fix / feature / hook is
  the expensive analytical part and can be done ahead of the serial re-application.

  **Constraint:** preserve commit `3c2b931` through the split.
---
id: REF-004
title: Extract spliced features into modules with their own schemas
workstream: WS-10
priority: p1
existing_ot: OT-016
source: docs/adr/ADR-0021-module-boundaries-and-schema-ownership.md
superseded_by: none
body: |
  **Problem: three features have no file of their own.** `AutoWorldBuff` and
  `AutoDonationPoints` live inside `World::Update()`; `SoloDungeonRepop`/`Leech` live in
  the spell pipeline. They are marked only by `// custom:` comments, which is why every
  upstream merge touches them.

  **Extract into `modules/mod-*`:** `mod-donation`, `mod-worldbuff`, `mod-solo-dungeon`,
  `mod-guildbank`, `mod-lft-botfill` (already its own file at `src/game/LFT/LFTBotFill.cpp`,
  648 lines).

  **Use the existing hook system** (`src/game/ScriptObjects.h`: `WorldScript`,
  `PlayerScript`, `AllSpellScript`, ~40 script classes). Add a core hook only where none
  fits, and each such hook is a separate reviewed commit in `twow-core`.

  **Per module:** `src/`, `conf/`, `data/sql/`, `t/`. Unit tests from day one.

  **Behaviour must be provably preserved:** write a characterization test **before** each
  move, not after.

  **Schemas:** create `cv_ops` (donation, worldbuff, guildbank) and `cv_bots`
  (playerbots). Forward migrations move our tables out of upstream schemas.
  Replay-guarded (`INSERT IGNORE ... WHERE NOT EXISTS`), real SHA-1 content hashes, never
  the literal `'manual'`. Collapse the three competing character-migration conventions
  (`database_updates/character/`, `character_updates/`, `wip_updates/`) into one.

  **Also:** promote `src/modules/PlayerBots` to `modules/mod-playerbots` so there is one
  module system rather than two.

  **Parallelizes well:** each module is its own directory, schema, tests and config. The
  only shared resource is a core hook. Do the playerbots promotion first — the others'
  extraction pattern depends on it.
---
id: REF-005
title: Triage the compiler warnings that --no-warnings was hiding
workstream: WS-50
priority: p2
existing_ot: none
source: CMakeLists.txt
superseded_by: none
body: |
  **The release build passed `--no-warnings` to GCC/Clang, hiding every diagnostic.**
  Removed in the containerization work; this is the backlog it exposed.

  **First full Linux build (gcc 14.2, Release, playerbots on): 0 errors, 105 warnings.**

  By class:
  | count | warning |
  |---|---|
  | 50 | `-Wdeprecated-declarations` |
  | 28 | `-Wwrite-strings` |
  | 8 | `-Wmultichar` |
  | 4 | `-Wattributes` |
  | 2 | `-Wpointer-arith` |
  | 2 | `-Wenum-compare` |
  | 1 | `-Woverflow` |

  By file:
  | count | file |
  |---|---|
  | 23 | `src/game/Anticheat/Config.cpp` |
  | 18 | `dep/include/rapidjson/document.h` (vendored) |
  | 9 | `src/game/World.h` |
  | 8 | `src/realmd/AuthSocket.h` |
  | 7 | `src/shared/Auth/HMACSHA1.cpp` |
  | 6 | `src/shared/Auth/Sha1.cpp` |
  | 6 | `src/shared/Auth/Hmac.cpp` |

  **Worth looking at first:** the deprecation warnings in `Sha1.cpp`, `Hmac.cpp` and
  `HMACSHA1.cpp` are OpenSSL 3.0 deprecations of the low-level `SHA1_Init`/`SHA1_Update`
  API. Those functions still work but are on a removal path, and this is authentication
  code. `-Wenum-compare` and `-Woverflow` are the classes most likely to be actual bugs.

  **Do:** triage into fix / suppress-with-reason / accept. Do not add `-Werror` until the
  backlog is empty. Vendored `dep/` warnings can be excluded rather than fixed.
---
id: REF-006
title: Stop writing revision.h into the source tree
workstream: WS-50
priority: p2
existing_ot: none
source: CMakeLists.txt
superseded_by: none
body: |
  **The build writes a generated file into the source directory.**

  `CMakeLists.txt:384` does:
  `configure_file(cmake/revision.h.cmake ${CMAKE_CURRENT_SOURCE_DIR}/src/shared/revision.h)`

  **Consequences:**
  - A **read-only source mount fails to configure** — confirmed:
    `CMake Error: Could not open file for write ... /src/src/shared/revision.h.tmp`,
    `System Error: Read-only file system`. Container builds have to mount the source
    read-write purely because of this.
  - Two builds from one source tree race on the same file.
  - The source tree is dirtied by building it (it is gitignored, so this is invisible
    rather than harmless).

  **Do:** write it into the build directory instead and add that directory to the include
  path. Check every consumer of `revision.h` still resolves.

  **Low risk, small change** — but it blocks hermetic and cached container builds, so it
  is worth doing before the CI story hardens.
---
id: REF-007
title: Decide whether LFT bot fill should become a module
workstream: WS-10
priority: p2
existing_ot: OT-016
source: src/game/LFT/LFTBotFill.cpp
superseded_by: none
body: |
  **Deliberately NOT extracted during the Phase C module work. Recording why, so
  the decision is not silently re-made.**

  The other three features (donation, world buffs, leech) were spliced into
  unrelated core functions — `World::Update()` and `Unit::DealDamage()` — with no
  file of their own. That is what made them worth extracting: they sat in the
  middle of the hottest functions in the tree and every upstream merge touched
  them.

  **LFT bot fill is different.** `src/game/LFT/LFTBotFill.cpp` (648 lines) already
  has its own file, so it causes none of that merge pain. What it does have is
  depth: it implements `LFTMgr::UpdateBotFill`, a method of the core manager, and
  touches **six private members** of it:

  - `m_queue`, `m_offers`, `m_playerOffers` — the LFT matching state
  - `m_lftGroupIds`, `m_fillBots` — bot-fill bookkeeping
  - `m_botFillTimer`

  Turning it into a module means exposing essentially the whole LFT queue through
  hooks. That is a large, fragile surface for a feature that is not currently
  costing anything, and the module would break on any LFT internal change.

  **If it is revisited, the question to answer first** is whether LFT should have
  a proper extension point — something like "offer candidates for an unfilled
  role" — rather than a module reaching into queue internals. That is a design
  job on LFT, not a mechanical extraction.

  Related: OPS-006 (bot grouping lifecycle is unbounded) and OPS-002 (fixed-count
  config defects) both touch the same subsystem and would inform the design.
---
id: REF-008
title: Decide the fate of four unexplained fork changes
workstream: WS-80
priority: p2
existing_ot: none
source: docs/adr/ADR-0020-two-repo-upstream-split.md
superseded_by: none
body: |
  **Four changes in the fork's core delta that nobody can explain from the
  commit history.** Each needs a decision before the upstream split, because
  each has to be classified as fix / feature / noise to be re-applied — and
  "unknown" is not one of the buckets.

  **1. A temporary diagnostic still in the tree.**
  `src/game/Objects/Player.cpp:2645` — a block self-labelled `DIAG(temp, Z-GEIST)`
  that logs an error line on every teleport into map 36 above a Z threshold. It
  was added to chase a dungeon-clear test tank parked somewhere wrong. Is the
  investigation finished? If so it should go; if not, it should say so.

  **2. `ForcePinAccountRank` changed from 1 to 6.**
  `src/realmd/realmd.conf.dist.in:143`. This effectively **disables forced
  two-factor authentication for ordinary accounts**. No commit message in range
  explains it. Deliberate server policy, or a leftover from testing? This is the
  one with a security consequence, so it should be answered first.

  **3. `Map::HasActiveZone()` and `HasActiveZones()` return unconditional `true`.**
  `src/game/Maps/Map.h:551-553`. The comment calls them stubs — cmangos has the
  concept, Penqle does not track active zones. But the names read as predicates a
  module would branch on, and nothing argues that `true` is the safe default. If
  a bot asks "is this zone active?" and always hears yes, what does it do?

  **4. An unused spell constant.**
  `src/scripts/spells/spell_warrior.cpp:11` defines
  `SPELL_WARRIOR_SHIELD_SPECIALIZATION_RAGE = 23602` and nothing reads it. Merge
  commit `83d2aa8` dropped the fork's AuraScript version in favour of Penqle's
  SpellScript; this looks like what was left behind. Probably just delete it.

  **Also worth a decision, lower stakes:** ~64 lines of `SC_LOG` worldport-ack
  instrumentation in `src/game/Handlers/MovementHandler.cpp` with no non-debug
  effect. Permanent diagnostic seam, or a finished investigation?
---
id: REF-009
title: Promote src/modules/PlayerBots to modules/mod-playerbots
workstream: WS-10
priority: p1
existing_ot: OT-016
source: docs/adr/ADR-0021-module-boundaries-and-schema-ownership.md
superseded_by: none
body: |
  **Goal: one module system instead of two, and delete the last thing that makes
  a module configure the shared CMake target.**

  Today playerbots is a separate static library under `src/modules/PlayerBots`,
  gated by its own `BUILD_PLAYERBOTS` option, with ~20 hand-written `file(GLOB)`
  blocks. It is not a `modules/` module, and that single fact is why
  `mod-dungeon-clear.cmake` reaches out and mutates the shared `modules` target
  with 25 playerbots include directories, a link to `playerbots`, and a global
  `-include AcCompat.h`. Its own comment says so.

  **The payoff:** once both are modules, `CollectModuleIncludeDirectories`
  publishes those paths automatically and the whole block deletes. The CI guard
  in `ci.yml` can then drop its known exception, and module #2 stops inheriting
  another module's AzerothCore name shim.

  **Design refinement found while scoping — declare it static-only.**

  The plan assumed the promotion required removing `src/game/PlayerbotStubs.cpp`
  first, because link-time stubs cannot work with `dlopen`. Scoping the actual
  symbols shows that is the wrong trade:

  - 6 `BotActionLog_*` diagnostic probes, called from 12 sites in `Unit.cpp` and
    `Spell.cpp` via inline `extern` declarations. Converting these to core hooks
    means six new entries in `ScriptObjects.h` **for logging** — a poor use of
    the hook surface.
  - 4 chat commands, registered unconditionally in `Chat.cpp:1004-1007`.
    Migratable to a `CommandScript`.
  - `World::InitPlayerbotsAtStartup()`. Migratable to a `WorldScript`.

  Dynamic linkage was never realistic for playerbots anyway: `mod-dungeon-clear`
  subclasses playerbots' strategy, action, trigger and value classes, so the two
  must live in the same library regardless. **So promote it as a static-only
  module** (`MODULE_MOD_PLAYERBOTS=static`, refusing dynamic with a clear
  message), keep the free-function seam, and the payoff still lands.

  **Steps:**
  1. `modules/mod-playerbots/src/` <- `playerbot/`, `ahbot/`, `botpch.*`,
     `cmangos-compat-*`. The ~20 GLOB blocks delete: the framework globs `src/`
     recursively with `CONFIGURE_DEPENDS`.
  2. `data/sql/{world,character}/` <- the module's `sql/` tree.
  3. `mod-playerbots.cmake` carries what cannot be inferred: `CMANGOS`,
     `MANGOSBOT_ZERO`, `ENABLE_PLAYERBOTS`, Boost (thread/filesystem/system),
     the `botpch.h` PCH, and MSVC `/Ob1` — the last is load-bearing, `/Ob2`
     ICEs the optimizer with C1001 on the templated strategy code.
  4. Retire `BUILD_PLAYERBOTS`; update `src/mangosd/CMakeLists.txt`,
     `.dockerignore`, `deploy/compose/db-init.sh` (`PB_SQL_DIR`), `ci.yml`,
     `AGENTS.md`, `INSTALL-LINUX.md`.
  5. Delete the 25 include dirs and the `target_link_libraries(modules PUBLIC
     playerbots)` from `mod-dungeon-clear.cmake`; make its `-include AcCompat.h`
     per-module rather than applied to the shared target.
  6. Drop the known exception from the `ci.yml` isolation guard.

  **Sequencing hazard:** `modules/CMakeLists.txt:242` iterates modules in sorted
  order, so `mod-dungeon-clear`'s `POST_TARGETS` runs before `mod-playerbots`
  exists. There is no inter-module dependency mechanism today; that needs solving
  as part of this, not after.

  **Verify:** static build with modules enabled; `ctest` still green; the
  isolation guard passes with no exception.
---
id: REF-010
title: mod-playerbots and mod-dungeon-clear compile the same headers with different macros
workstream: WS-10
priority: p2
existing_ot: none
source: modules/mod-playerbots/mod-playerbots.cmake
superseded_by: none
body: |
  **The two modules disagree about what the bot classes are, and the compiler is
  not told.**

  `mod-playerbots` compiles its own sources with `CMANGOS`, `MANGOSBOT_ZERO` and
  `ENABLE_PLAYERBOTS` defined. They are `PRIVATE`, so `mod-dungeon-clear` — which
  subclasses those same classes and includes those same headers — compiles them
  with none of the three.

  Anything behind those macros therefore has two definitions in one program:
  different members, different layouts, different inline bodies. That is an ODR
  violation, and the failure mode is not a compile error but a wrong vtable or a
  field read at the wrong offset at runtime.

  **Not introduced by the module promotion.** The root `CMakeLists.txt` had
  `target_compile_definitions(playerbots PRIVATE CMANGOS MANGOSBOT_ZERO
  ENABLE_PLAYERBOTS)` before it, with the same consequence. The move preserved
  the behaviour deliberately rather than quietly changing it.

  **To do:**
  1. Measure it: compile a `mod-dungeon-clear` TU with and without the three
     macros and diff the layout of the classes it derives from
     (`-fdump-lang-class` on GCC, or a `static_assert(sizeof(...))` probe).
  2. If any derived-from class differs, make the definitions `PUBLIC` and rebuild
     `mod-dungeon-clear` against them.
  3. If nothing differs, say so in the cmake file with the evidence, so the next
     reader does not have to re-derive it.
---
id: REF-011
title: patches/llm-debug-only.patch applies to paths that no longer exist
workstream: WS-10
priority: p2
existing_ot: none
source: patches/llm-debug-only.patch
superseded_by: none
body: |
  The patch targets `source/src/modules/PlayerBots/...`. That tree is
  `modules/mod-playerbots/src/...` now, so the patch cannot apply.

  Decide which it is:
  - still needed -> rewrite the paths and record what applies it and when;
  - already merged or obsolete -> delete it. It stays in git history.

  Nothing in the build or the deployment references it, which is itself the
  question: a patch file nobody applies is either dead or a missing step.
---
id: REF-012
title: Burn down the 25 core headers that are not self-contained
workstream: WS-10
priority: p2
existing_ot: none
source: ops/audit/header-self-containment-baseline.txt
superseded_by: none
body: |
  **25 of 216 headers under `src/game` do not compile on their own.** They use a
  type without declaring it, and get away with it only because every translation
  unit that reaches them happens to include the declaration first.

  Four of these were found the expensive way in one afternoon — `Conditions.h`,
  `SharedDefines.h`, `WorldSession.h`, `LFTMgr.h` — each by a Windows CI job,
  twelve minutes at a time, because GCC's include order in this tree is luckier
  than MSVC's. All four are fixed; these 25 are the rest, found by
  `ops/audit/header-self-containment.sh` and baselined so CI fails on a new one
  but not on these.

  **The list** is `ops/audit/header-self-containment-baseline.txt`. Reproduce
  with:

      cmake -S . -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
      ops/audit/header-self-containment.sh build

  **Most are one line.** The causes cluster:
  - missing `Platform/Define.h` (`uint32` undeclared) — `GenericSpellAI.h`,
    `HonorMgr.h`, `NPCHandler.h`, `GridMapDefines.h`,
    `CharacterDatabaseCleaner.h`
  - missing `ObjectGuid.h` — `CreatureGroups.h`, `LFGMgr.h`
  - missing a standard header — `<thread>` in `ChannelBroadcaster.h`,
    `<vector>` in `NPCHandler.h`
  - missing `Chat.h` / `World.h` — `AnticheatChatCommands.h`,
    `AsyncCommandHandlers.h`, `GuidObjectScaling.h`

  **Check before fixing** whether a header is *meant* to be included from one
  place only: `spline.impl.h` and `MovementGeneratorImpl.h` look deliberate. Those
  should stay in the baseline with a note saying why, not be forced standalone.

  **Fix them upstream-first.** Most are upstream files and these are plain bug
  fixes, so they belong in the ADR-0020 batch that goes to `twow-core` as
  individually PR-able commits — not carried as fork delta forever.

  **Done when** the baseline file is empty or contains only headers with a
  recorded reason, and the CI step still passes.
---
