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
