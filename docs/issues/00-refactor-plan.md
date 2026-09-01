# Initial refactor: separate upstream, modularize, containerize, test

Branch: **`refactor/modular-platform`**, rebased onto `main` at each phase boundary (`main` keeps advancing).

**Scope note.** Earlier drafts of this plan carried the whole future architecture — external bot brain, persona/memory/canon, WASM policies, headless clients. Per your call, that is **out of scope for this refactor**. It is not discarded: it is written up in full detail as GitHub issues (see *Deferred work* below), so the refactor stays finishable and the design work isn't lost.

**In scope:** foundations + tests + CI/CD, one-command build and run, the upstream split, feature modules with their own schemas, ADRs, and the issue tracker.
**Out of scope, captured as issues:** bot-brain externalization, persona/memory/canon, roster and LLM-bridge integration, WASM, headless clients.

## Context

`Cilverkrow/twow-repo` is a WoW 1.12 / Turtle-1.18.1 private server (mangos-zero / VMaNGOS lineage) whose defining feature is ~1000 playerbots. It works. But it is one merged tree where upstream code, fork fixes, fork features and governance evidence are indistinguishable, and it has no automated verification of any kind:

- **No upstream boundary.** 114 core files differ from upstream tip `db5fb2a` (+5246/−1809), concentrated in the highest-traffic upstream files (`Player.*`, `World.*`, `Unit.*`, `WorldSession.cpp`, `CharacterHandler.cpp`). Three fork features — `AutoWorldBuff`, `AutoDonationPoints`, `SoloDungeonRepop`/`Leech` — have **no file of their own**; they are spliced into `World::Update()` and the spell pipeline, marked only by `// custom:`. Every upstream merge is a hand fight, and our genuinely upstream-worthy fixes cannot be PR'd back in that shape.
- **No CI, and the one C++ test suite cannot build.** `.github/` has no workflows. `modules/mod-dungeon-clear/t/` has 54 gtest files (~900KB), but googletest is never fetched, and neither `src/test/mocks/TestMap.cpp` nor the `game-interface` target it links exists. No `enable_testing()`/`add_test()` anywhere. Everything else called a "test" is a Windows PowerShell evidence script under `runbooks/`.
- **Not runnable in one command; not containerizable as-is.** No Dockerfile, no compose. Four blockers, all verified: `CMAKE_INSTALL_PREFIX` is compiled into the binary (`SYSCONFDIR`, `CMakeLists.txt:637` → `PlayerbotAIConfig.h:16`) so build-then-copy silently ships a botless server; `-march=native` (`CMakeLists.txt:496`) makes images host-specific; `mangosd` exits on stdin EOF; and `AutoUpdater.cpp:238` blocks on `std::getline(std::cin, …)` when a migration fails, hanging a headless container forever.
- **Migrations are not trustworthy.** `AutoUpdater.cpp` keys on `Module + ":" + SHA1(file bytes)` in a `migrations` table — sound in principle — but the documented bootstrap backfills the tracker with the literal string `'manual'` (OT-015, FG-033), so much of history is neither proven applied nor suppressed. `sql/setup_databases.sh` skips `sql/base` entirely and doesn't recurse into `database_updates/{world,character}`. `cmake/migrations.cmake` is dead code pointing at a nonexistent `sql/migrations/`. There are **three competing conventions** for "a character migration".

Goal of *this* refactor: separate upstream from ours so our fixes can go home; make our features modules with their own schemas and migrations; one-command build and run on Linux and Windows; and real automated tests behind all of it.

## Confirmed lineage

```
mangos-zero / VMaNGOS  (+ AzerothCore ports)
  └── Penqle/tortoise-wow                    Turtle 1.18.1 restoration; the modules/ script system; ScriptObjects.h
        └── r-o-sh playerbots-integration-gh vendors ike3's cmangos playerbots
              └── Shyalya/tortoise-wow @ playerbots-integration-gh   ← the actual upstream
                    └── Cilverkrow/twow-repo (this repo; history filtered to strip binaries)
```

`kasperfriend/tortoise-oneclick-compiler` — where the project started — builds `Shyalya/tortoise-wow`; `ops/windows/build/compile-tortoise-wow.ps1` here is its descendant. This gets written down as **ADR-0026**, because right now it exists nowhere in the repo and had to be reconstructed from GitHub.

Two pieces of directly reusable prior art:

1. **`Nescabir/tortoise-docker` / `kasperfriend/tortoise-docker`** already publish Docker images of exactly this fork: `mangosd`, `realmd`, `db`, `db-init`, GHCR-hosted, built `x86-64-v2` for portability, client data volume-mounted, stdin solved with a FIFO at `/opt/turtle/run/mangosd.in`. Adapt, don't invent.
2. **`modules/mod-dungeon-clear/.github/workflows/`** — four well-reasoned workflows already in this tree, dormant because they only fire in the module's own repo: `tests.yml` (gtest + ccache), `upstream-smoke.yml` (nightly build against upstream staging to catch API drift), `windows-smoke.yml` (Ninja + MSVC, compiles only the module's objects), `testdeck.yml`. These are the CI templates.

## Update: state as of `29ef68d` (pulled after this plan was first drafted)

Three commits landed and they change several conclusions. **This plan is now OT-025** in `TODOS.md` ("Claude Code repository restructuring"), and `docs/HANDOVER-CLAUDE-CODE.md` is its brief.

- **OT-001 is done.** The persistent roster is integrated on `main` as commit `3c2b931` — 28 paths, including `PersistentActiveRoster{,Database}.{cpp,h}`, a migration (`sql/character_updates/20260830230336_…`), a rollback, `src/modules/PlayerBots/tests/` with fixtures, and a new root option `BUILD_PERSISTENT_ROSTER_ADAPTER_TESTS` (default OFF). It also modified **core** `src/shared/Database/{Database,DatabaseMysql}.{cpp,h}`, which matters for the upstream split. Deferred issue #3 is therefore closed; what replaces it is **OT-024** (roster expansion and capacity proof: 50→100→250→500, with startup/login/CPU/RAM measurement).
- **ADR-0018 and ADR-0019 now exist** (runbook evidence retention; external Windows build inputs). All ADR numbers proposed here shift up — the new ones start at **ADR-0020**.
- **OT-026 settles the runbook question**, and in the direction I recommended: keep sanitized text-only runbooks in place for this restructuring; evaluate a separate evidence repository later, only with stable IDs, link migration and retention policy. So bucket-C deletion is explicitly off the table for now. Good — that's now a decision rather than my suggestion.
- **ADR-0019 is a hard constraint on Windows CI** (detailed below). It also raises the handover's open question: how a build agent provisions those inputs without shipping them in Git.

Per your instruction: where these documents were written against the pre-restructuring repository, **our decisions here are authoritative**; where they record verified facts (build identity, the 28-path delta, the external-input boundary), they are evidence and this plan defers to them. The one thing the handover asks that this plan must honor literally: `3c2b931` is the tested OT-001 baseline and must not be rewritten during restructuring.

## Decisions that shape this refactor

### Where the bots are computed (context for the deferred work)
Entirely in-process in `mangosd`, on the map-update threads. `Player::Update()` fires `PLAYERHOOK_ON_UPDATE` → `PlayerbotAI::UpdateAI` → `Engine::DoNextAction`. Bots build a `WorldSession` with a **null socket** and load the character straight from the DB — they never enter the socket/queue path a real client takes, and never count against `PlayerLimit`. That's why in-process is cheap: no serialization, no encryption, no round trip, and every trigger/action/value reads live `Player*`/`Unit*` on demand. It's also why moving the AI out is a re-implementation rather than a port — which is exactly why it's deferred.

### Upstream split: two repos joined by a submodule
- **Submodule** = a pointer: your repo stores a URL and a commit SHA; upstream's files aren't in your history. Clone needs `--recursive`.
- **Subtree** = upstream's files are copied *into* your repo at a prefix and its history merged in. Normal clone, `git subtree pull`/`push`. Heavier history, fiddlier merges — and this repo's history was rewritten to strip binaries, so it can't cleanly share history with upstream anyway.

Given "avoid in-repo vendoring" **and** "we want to upstream our fixes":

- **`twow-core`** — a genuine fork of `Shyalya/tortoise-wow`, cloned fresh so it shares real history with upstream. Our 114-file core delta is re-applied as small, single-purpose, individually PR-able commits. This is where `git pull upstream` is normal and where the battleground-queue mutex fix becomes an upstream PR.
- **`twow-repo`** (this repo) — the platform: modules, deploy, docs, our SQL. References `twow-core` as a submodule pinned by SHA.

`core-patches/` remains a **review artifact** — the numbered series generated from `twow-core`'s branch in CI so a reviewer sees the whole core delta at a glance — but the source of truth is commits in `twow-core`.

### Per-module migrations and schema ownership — the mechanism already exists
`AutoUpdater.cpp` already scans `modules/<name>/data/sql/{auth,character,world}/` for every module in `TW_ENABLED_MODULES`, gated by `Database.AutoUpdate.AllowedModules`, tracked as `Module:SHA1(bytes)`. Per-module migrations are supported **today**; what's missing is schema *ownership* and a working bootstrap.

| Schema | Owner | Migrations run by |
|---|---|---|
| `tw_world`, `tw_char`, `tw_logon`, `tw_logs` | upstream (`twow-core`) | core AutoUpdater, upstream files only |
| `cv_bots` | `mod-playerbots` | `modules/mod-playerbots/data/sql/` |
| `cv_ops` | `mod-donation`, `mod-worldbuff`, `mod-guildbank` | each module's `data/sql/` |

One schema, exactly one owner. Future services get their own schemas and their own tool (goose) when they arrive — that's in the deferred issues, not here.

### Bot behaviour: the identity/behaviour seam already exists and is tested

The behaviour work your collaborator did is now in the tree, and it is the most important architectural asset the roster commit brought. `PersistentActiveRoster.h:110-125` defines a 13-flag `RuntimeBehaviorPolicy`, resolved by `EvaluateRuntimeBehaviorPolicy(persistentRosterMember, grouped)`:

```
clearExpiredValues   normalAiTicks       normalStrategyMaintenance
travelAndIdleBehavior  revive            sessionMaintenance
scheduleNextUpdate   leaseLogout         populationRotation
randomizeProgression randomStrategyReassignment  randomTeleport
automaticGroupRemoval
```

This draws a precise line between **behaviour** (the bot keeps ticking, travelling, reviving, maintaining strategies and its session) and **identity churn** (lease logout, population rotation, random progression/strategy/teleport re-rolls, automatic group removal). A persistent roster member keeps the first set and loses the second; being grouped suppresses more still.

It exists because the naive fix failed: FG-047 records that a broad early return to stop rotation also killed AI cleanup, travel, revive, strategy and session maintenance — bots that technically persisted but stood still. The guardrail is stated as "disable only identity rotation/logout effects and test organic behavior".

**One correction, because it matters before anyone leans on this struct: only 3 of the 13 flags are actually consulted.** `RandomPlayerbotMgr.cpp` reads `leaseLogout` (:2549), `populationRotation` (:2551) and `randomizeProgression` (:2692). `randomStrategyReassignment`, `randomTeleport`, `automaticGroupRemoval` and the seven always-true flags are declared but never read — their intent is enforced instead by hard membership checks (`RandomizeFirst` early-return at :3536, and the `PersistentRosterDestructiveMutationAllowed` gates). So the struct is currently half live policy, half documentation. That's fine as an intent record, but a future planner must not assume setting a flag changes behaviour.

The genuinely new behavioural surface is not AI at all — it's a **fail-closed admission and destructive-mutation veto**: `AddPlayerBot` revalidates membership and account state before login; `LogoutPlayerBot`/`DisablePlayerBot`/`DeleteBot` refuse for roster members; `Remove()` and `HandleConsoleReset` refuse while the roster is enabled; failures schedule an exponential retry (capped at 6 attempts, `min(1<<attempt, 60)`s) and log `DEGRADED … no replacement selected` rather than substituting a bot.

Three consequences for this refactor:
- **This is the contract the deferred bot-brain must respect.** The identity/behaviour split is decided and tested; an external planner must never assume it may relocate or re-roll a bot.
- **It belongs to `mod-playerbots`**, and the Phase 3 extraction must keep it intact with its tests green.
- **The core coupling is small and cleanly separable**: 47 additive lines across 4 `src/shared/Database` files — a new `SqlConnection::AffectedRows()` virtual with a default body, and `Database::DirectTransaction(std::function<bool(SqlConnection&)>)` for a synchronous single-connection all-or-nothing transaction. No existing signature changed. That's an ideal upstream patch candidate. **One latent bug to fix on the way**: `Database.h:242` uses `std::function` without including `<functional>` — MSVC pulls it in transitively, libstdc++ may not, so this can break the Linux build.

### Bot behaviour: what is NOT in the repo

Worth saying plainly, because it changes what you can plan against. **There is no collaborator specification of bot behaviour or cohorts in this repository.** I searched for it specifically:

- "Cohort" appears only as loose prose for "the current set of bots" (`PLAYERBOTS_QUICKSTART.md`), as SQL comments, and as `ACTIVE-ADD-COHORT.tsv` — which is a **query result with a header row and zero data rows** (the C0 report confirms zero active RNDBOTs), not a design document.
- The one place your collaborator's topics appear together is a single sentence in `runbooks/playerbot-discovery-matrix-preflight-02-20260830-173815/report.md`, and it lists them **as deferred**: "Any fixed-count source correction, GUID-cohort mechanism, profession pairing, spec behavior, grouping lifecycle, gear scoring, gathering, quest turn-in, or LLM context remains a separate candidate and rollback point."
- What *does* exist is population/distribution analysis in that same report: 59 schema race/class pairs vs 52 the factory supports; time-based rotation confirmed with 1800–21600s per-login lifetimes and a 120-second deferral for grouped bots; level cap does not trigger replacement; weighted allocation matrices ready for 50/100/500/1000 targets; effective low-level roles Tank 719 / Healer 362 / DPS 3419 across 4,500 stock bots. Planning matrices only — no GUIDs, no behaviour rules.

So if he discussed grouping lifecycle, reactions, activity scheduling or cohort tiers, that discussion is in a chat and not in Git. **Ask him to write it down before we plan around it** — I'd rather flag the gap than invent a specification. It becomes an issue either way.

### Database: MariaDB, not Postgres

You guessed right, and it's worse than "the migrations are MySQL-flavoured". Measured:

- There **is** a Postgres backend in the tree — `DatabasePostgre.{cpp,h}`, `QueryResultPostgre.{cpp,h}`, `PGSQLDelayThread.h`, all listed in `src/shared/CMakeLists.txt`. It's inherited MaNGOS code, **untouched since the initial upload (2025-12-16)**, and gated on `DO_POSTGRESQL` — a macro that appears only in `#ifdef` guards across 10 files and **is never defined by any build file**. It has never been compiled here. Treat it as 15-year-old dead code, not as an option.
- The data is the real lock-in: **161 files in `sql/base` declare `ENGINE=MyISAM`**, 36 files under `database_updates` use `INSERT IGNORE`/`REPLACE INTO`, `create_databases.sql` is full of `AUTO_INCREMENT`, and all 190 base files are `mysqldump` output with backtick quoting and `LOCK TABLES`. Porting means rewriting 359 SQL files *and* the DB layer *and* the AutoUpdater — and `3c2b931` just added MySQL-specific changes to `DatabaseMysql`.

So: **one database, MariaDB.** That also happens to be the better answer for the deferred memory work, because MariaDB 11.8 has native `VECTOR` + HNSW — the RAG store needs no second datastore. Between MariaDB and MySQL, MariaDB is the right pick: it's what the Linux install is verified on (11.8), what the ops scripts use, what upstream's docker images use, and it's the one of the two with vector search in an LTS release.

One consistency job for this refactor: `INSTALL-LINUX.md` verifies **11.8** while `ops/windows/build/compile-tortoise-wow.ps1:49` pins **11.4.10** (no `VECTOR` type). Pin 11.8 everywhere.

### Platform: native builds both sides, no Wine

No Wine, and it would be the wrong tool. The server is portable C++ with CMake; only **28 of ~1,978 source files** carry `_WIN32` guards, and `INSTALL-LINUX.md` documents a real running Debian 13 / gcc 14.2 / MariaDB 11.8 install. We compile native binaries for each target. Wine only helps when you must run a Windows *binary* on Linux — we never need to, and it cannot run MSVC meaningfully, so it would buy false confidence instead of coverage.

Windows still earns a place in CI for real reasons: MSVC catches a class of errors gcc/clang don't (the `windows-smoke.yml` header in `mod-dungeon-clear` documents exactly this with `M_PI`), and the production server currently runs on Windows.

**But ADR-0019 blocks a naive Windows job**, and I verified the boundary exactly:

| Input | In Git? | Consequence |
|---|---|---|
| `dep/windows/include` (MySQL headers) | **yes**, 168 tracked files | Windows *compilation* works from a clean clone |
| `dep/windows/lib/x64_release/libmySQL.lib` | **no** — directory absent | Windows *linking* fails |
| `src/mangosd/mangosd.ico` (16,958 B, SHA-256 pinned in `docs/BUILD-RESOURCES.md`) | **no** | `mangosd.rc` resource compile fails |

That boundary gives a clean two-tier design, which is also the answer to the handover's open question about provisioning:

- **Tier 1 — compile-only MSVC smoke.** Ninja generator, build object files for `game`/`shared`/`framework`/modules, never link, never touch the `.rc`. Needs **no external inputs**, so it runs on every PR including from forks. This is exactly the trick `mod-dungeon-clear/.github/workflows/windows-smoke.yml` already uses, and its header explains why (building `--target modules` would drag in ~635 unrelated TUs).
- **Tier 2 — full link.** Requires the provisioned `.ico` and import libraries, verified by byte count and SHA-256 before use and removed afterwards per ADR-0019. Runs only on the main repo, from a private artifact source, gated on the `windows-full` label or a nightly schedule.

**Linux has no such constraint, and that inverts the project's current Windows-primary assumption.** `src/mangosd/CMakeLists.txt:33` adds `mangosd.rc` only `if(WIN32)`, and Linux links system `libmysqlclient`/OpenSSL rather than `dep/windows/lib`. So **a clean `git clone` builds completely on Linux and cannot on Windows.** Linux therefore becomes the hermetic, fork-friendly, complete gate — gcc + clang, full link, tests, containers, everything — and Windows is the partial one. ADR-0019 says this outright ("A clone alone is intentionally insufficient for a Windows server build"), and FG-071 records the exact failure mode: a text-only checkout configures and compiles most targets, then fails late at resource and link stages.

### The SQL: 189MB, and it isn't ours
Measured: `sql/base` is 130.2 MiB across 190 files — a per-table **mysqldump of a live `tw_world`** (MariaDB 10.6.22) with data. 44% of it is translation tables (`locales_*` = 57 MB; `locales_quest` alone 24.5 MB). `git log -- sql/base` shows **9 commits, ever**, all upstream authors; no fork commit touches it. `sql/database_updates` is 56.2 MiB, of which the three largest files (35.2 MB) are bulk re-imports whose rows are **56–89% already in `sql/base`** per the repo's own `sql/tools/migration-overlap-report.txt`. Schema is stored twice (`create_databases.sql` vs the `CREATE TABLE` in each base file) and has already drifted (`module_string*`). SQL is ~58% of the 115.65 MiB pack; no git-lfs anywhere.

**So it moves with upstream into `twow-core`.** Repo weight solves itself as a side effect of the split, and this repo keeps only `sql/` we author.

## Project ground rules (invariants)

Constraints every phase is checked against, recorded as **ADR-0024** and enforced by tests where possible.

**Why invariant #1 is urgent, not theoretical.** "Cohort" in this project means the bot population created together, and the legacy random-bot system is built to destroy it: `PLAYERBOTS_QUICKSTART.md:93-97` documents `AiPlayerbot.DeleteRandomBotAccounts = 1` as a one-shot reset that **"will wipe and recreate the cohort on every subsequent restart"** if you forget to set it back to `0`. A single stale config value silently erases every bot identity, and nothing in the system objects. That is exactly what the persistent roster (`3c2b931`) exists to replace, and exactly why the invariant needs enforcement in CI and config validation rather than in a comment.

1. **Bots are persistent. A bot must never be lost.** A bot keeps its character, GUID, items, progression, relationships and history across restarts, migrations, rotations, deployments and refactors. No code path may silently delete, replace, substitute or re-roll a bot identity. If a roster member can't be resolved, the system enters `DEGRADED` and says so — it never fills the gap with a different bot. Partially backed already by ADR-0010/0011 and FG-044; ADR-0024 raises it to a project invariant binding every future module and service. Enforcement: a persistence conformance test in the smoke suite (record roster → restart stack → assert identical GUIDs, item counts, progression), plus a CI guard failing any `DELETE`/`TRUNCATE` against character or roster tables outside an explicitly authorized migration.
2. **Upstream schemas are read-only to us.** Enforced by a CI check on migration targets.
3. **Migrations are forward-only and replay-safe.** No editing applied migrations, no down-migrations, real content hashes, never the literal `'manual'` (FG-032, FG-033).
4. **The core must run with every one of our features disabled.** Enforced by a CI job that builds and smoke-tests with all modules off.
5. **No secrets, no binaries, no client data in Git** (ADR-0004), enforced by gitleaks and a file-size/type gate.
6. **Fail closed.** Our paths degrade to core behavior rather than to wrong behavior; an unavailable dependency never blocks or crashes the world thread.

## Target structure

```
twow-repo/                     the platform (~40MB after the split)
├── core/                      → submodule: twow-core @ pinned SHA
├── core-patches/              generated review artifact (0001-*.patch)
├── modules/
│   ├── mod-playerbots/        the vendored bot engine, promoted to a real module
│   │   ├── src/  conf/  data/sql/  t/
│   ├── mod-dungeon-clear/     (already shaped this way)
│   ├── mod-donation/          extracted from World::Update()
│   ├── mod-worldbuff/         extracted from World::Update()
│   ├── mod-guildbank/  mod-lft-botfill/  mod-solo-dungeon/
├── deploy/
│   ├── docker/                Dockerfile.core, entrypoints
│   ├── compose/               docker-compose.yml + profiles
│   └── helm/twow/             chart
├── test/
│   ├── unit/  integration/  smoke/
├── docs/                      ADRs, footguns, contracts
├── ops/                       build/run helpers, Linux + Windows
└── sql/                       only what we author
```

`services/` and `test/fixtures/snapshots/` are deliberately absent — they arrive with the deferred work.

## Phases

Each phase is a PR into `refactor/modular-platform`, each ends green in CI, each independently revertible.

### Phase 0 — Foundations (no behavior change)
1. Branch `refactor/modular-platform`.
2. **Fix the build so it can be containerized**: replace `-march=native` with `-march=x86-64-v2` behind a `TW_ARCH` cache variable (`CMakeLists.txt:496`); drop `--no-warnings`; make `SYSCONFDIR` runtime-resolvable with the compile-time value as fallback (`PlayerbotAIConfig.cpp:100` started this — finish it for `ahbot.conf` at `AhBotConfig.cpp:28`); add a non-interactive mode so `AutoUpdater.cpp:238` fails loudly instead of blocking on stdin.
3. **Make the test infrastructure real.** There are now *two* disconnected suites, and neither runs from a plain build:
   - `modules/mod-dungeon-clear/t/` — 54 gtest files, but googletest is never fetched and the `src/test/mocks/TestMap.cpp` and `game-interface` targets it links don't exist.
   - `src/modules/PlayerBots/tests/` — new with `3c2b931`, and it is actually **two** targets with different wiring. `persistent_active_roster_database_tests` **is** in the main build (`src/modules/PlayerBots/CMakeLists.txt:161-194`, behind the new root option `BUILD_PERSISTENT_ROSTER_ADAPTER_TESTS`, default OFF) — 48 assertions plus a real multi-threaded concurrency scenario against a disposable MariaDB. `persistent_active_roster_tests` (the pure unit suite, 7 functions / **142 assertions**) is **not wired in at all**: `tests/CMakeLists.txt` is a standalone `project()` with no `add_subdirectory` anywhere, hard-requiring an external `ROSTER_TEST_OPENSSL_LIBRARY` import library, unconditionally adding `dep/windows/include`, and driven by `run-tests.ps1` with a hard-coded CMake path and the VS 2022 generator. Neither uses a test framework — both are hand-rolled `CHECK` macros counting failures.

   Work: `enable_testing()`/`include(CTest)` at root; `FetchContent` googletest pinned by tag; create the missing `TestMap.cpp` mock and `game-interface` target; `add_subdirectory(tests)` behind a new `BUILD_PERSISTENT_ROSTER_UNIT_TESTS` option, dropping the standalone `project()`; replace the raw `ROSTER_TEST_OPENSSL_LIBRARY` filepath with `find_package(OpenSSL REQUIRED)` + `OpenSSL::Crypto`; **guard the `dep/windows/include` include dir** — unconditional, it shadows system OpenSSL headers on Linux; register everything with `add_test()`, with the adapter test only registered when a connection string is supplied. Success = `ctest` runs both suites on both platforms.

   Preserve the roster tests' behaviour exactly — `3c2b931` is the tested OT-001 baseline and must not be rewritten (`TODOS.md` guardrail, FG-072). Wiring and portability changes only.

   **One real bug to file while here:** `PersistentActiveRoster.cpp:135-155` validates canonical admin requests differently per platform. The Windows branch checks UTF-8 **and NFC normalization** via `IsNormalizedString`; the POSIX `#else` branch only checks UTF-8 well-formedness. A non-NFC actor or reason string is therefore **rejected on Windows and accepted on Linux** — divergent canonical-request acceptance, which matters because the whole roster contract is built on canonical bytes and SHA-256 digests.
4. **CI** — `.github/workflows/`, adapted from the four dormant workflows in `modules/mod-dungeon-clear/.github/workflows/`:

   | Workflow | Trigger | Does |
   |---|---|---|
   | `build-linux.yml` | PR, push | matrix gcc-14 / clang, ccache, `-march=x86-64-v2`, full link |
   | `build-windows.yml` | PR (paths-filtered), push | MSVC + Ninja, compile-only for speed |
   | `test.yml` | PR, push | `ctest`; coverage upload |
   | `integration.yml` | PR, nightly | compose up ephemeral MariaDB, migrations from empty |
   | `smoke.yml` | PR, push | the `make smoke` gate, incl. bot-persistence conformance |
   | `lint.yml` | PR | all non-compilation checks (below) |
   | `upstream-smoke.yml` | nightly | build against upstream tip to catch API drift early |
   | `publish.yml` | tag, main | build + push images to GHCR, package + push Helm chart |

   `lint.yml` covers everything that isn't a compiler: `clang-format`/`clang-tidy`, `buf lint` (once protos exist), `sqlfluff` on migrations, `hadolint`, `shellcheck` and `PSScriptAnalyzer`, `yamllint`, `markdownlint` + a dead-link check across `docs/` (the 46 runbook citations must resolve), `gitleaks` (respecting the one audited `.gitleaksignore` entry and failing on any broadening), `helm lint`/`helm template`, a **binary/size gate**, a **boundary check** failing a PR that touches `core/` without the `core-change` label, and a **schema-ownership check** rejecting a migration targeting a schema its module doesn't own.
5. **Rewrite `AGENTS.md`** (see below) — governance kept, engineering section added, paths normalized.
6. **Smoke tests in `test/smoke/`**: compose up → realmd accepts a connection on 3724 → worldserver listens on 8090 → `migrations` table has the expected count → console responds → a bot logs in → clean shutdown leaves no dirty state. The gate every later phase must keep green.
7. **Set up issue tracking** (see below) and import four sources as issues: this plan's deferred work, `docs/OPEN-THREADS.md` (OT-001…OT-022), your friend's task markdown, and — per his point — **a fresh sweep of `runbooks/` for still-open tasks**. That sweep is a real analysis job, not a copy: `runbooks/` is 1,299 files across 49 top-level directories, many of them superseded or blocked runs, so the work is separating live open threads from closed evidence. It must run **against a freshly pulled `main`**, because `main` will have advanced past this planning session. Deliverable: a reviewed manifest under `docs/issues/` before any issue is created.

### Phase 1 — One-command build and run
8. `deploy/docker/Dockerfile.core` — multi-stage Debian 13, **same `CMAKE_INSTALL_PREFIX` in both stages** (this is the trap), `x86-64-v2`, ACE 7+/Boost/MySQL/OpenSSL from apt.
9. `deploy/compose/docker-compose.yml` — `db` (MariaDB), `db-init`, `realmd`, `mangosd`, with a `dev` profile. Entrypoint holds the FIFO open for mangosd's console (the tortoise-docker pattern); health checks on all four. **Pin MariaDB 11.8** — the Linux docs verify 11.8 while `ops/windows/build/compile-tortoise-wow.ps1:49` pins 11.4.10; that divergence should not survive this refactor.
10. Client data stays a **volume mount**, never in an image — legally and practically. A `tools` profile runs the extractors (`mapextractor`, `vmapextractor`+`vmap_assembler`, `MoveMapGen`) against a mounted client; budget an hour or more for mmaps.
11. `make up` / `.\ops\up.ps1` as the one command, wrapping compose. `make test` runs unit + smoke.
12. **GHCR publishing** — `publish.yml` builds and pushes `ghcr.io/cilverkrow/{mangosd,realmd,db-init}`, tagged by semver on release and commit SHA on `main`, with provenance attestation and an SBOM. Built once, promoted, never rebuilt per environment.
13. **Helm chart** — `deploy/helm/twow/`: `mangosd` (StatefulSet — one world server per realm, persistent volume for client data), `realmd` (Deployment), `mariadb` (dependency chart or external), migrations as pre-upgrade Jobs, secrets via `existingSecret` only, and a `values-dev.yaml` mirroring the compose file so the two never diverge. `helm lint` + `helm template` in CI from the start; chart published to GHCR as an OCI artifact.

### Phase 2 — The upstream split
14. Create `twow-core` as a fresh clone of `Shyalya/tortoise-wow` with a real `upstream` remote.
15. Re-apply our core delta as **small single-purpose commits**, each either (a) a bug fix that should go upstream or (b) a hook/seam our modules need. Upstream-worthy fixes first (BG queue mutex, null anticheat on bot sessions, `DealDamage` branch, `Engine::Init` flag inversion, the `vfprintf` format-string abort, Healing Touch's dangling `ownerAura`) so they can be sent home immediately.
16. Feature code spliced into upstream files (`AutoWorldBuff`, `AutoDonationPoints`, `SoloDungeonRepop`/`Leech`) is **not** re-applied — it becomes modules in Phase 3.
17. `twow-repo` gains `core/` as a submodule + `UPSTREAM.lock` recording the pinned SHA, upstream URL and merge-base. `core-patches/` generated in CI so the review artifact never drifts.
18. `sql/base`, `sql/database_updates`, `sql/create_databases.sql` move to `twow-core`. Fix `setup_databases.sh` there to import `sql/base` and recurse.

### Phase 3 — Feature modules and schema ownership
19. Extract each spliced feature into `modules/mod-*` using the existing hook system (`ScriptObjects.h` — `WorldScript`, `PlayerScript`, `AllSpellScript`, …), adding a core hook only where none fits; each such hook is a separate reviewed commit in `twow-core`.
20. Each module gets `conf/`, `data/sql/`, and **unit tests from day one**. Behavior is pinned by a characterization test written *before* the move, so each extraction is provably behavior-preserving.
21. Create `cv_ops` / `cv_bots`; forward migrations move our tables out of upstream schemas. Replay-guarded (`INSERT IGNORE … WHERE NOT EXISTS`), real SHA-1 hashes. Collapse the three character-migration conventions into one.
22. Promote `src/modules/PlayerBots` to `modules/mod-playerbots` so there's one module system, not two.

That is the end of the refactor. Everything past this point is an issue.

## Execution: what is serial and what parallelizes

**Phases 0–2 are a serial spine** — they define the structure everything else attaches to, and doing them concurrently just creates conflicts against a moving layout. Phase 3 fans out.

```
SPINE (serial)
  Phase 0  build fixes + test infra + CI skeleton + issues
     ↓
  Phase 1  Dockerfile + compose + GHCR + Helm
     ↓
  Phase 2  twow-core split + submodule + sql moves     ← after this, fan out
     ↓
  ┌──────────────┬──────────────┬──────────────┬──────────────┐
  │ Track A      │ Track B      │ Track C      │ Track D      │
  │ modules      │ CI/CD polish │ Helm/k8s     │ docs/ADRs    │
  ├──────────────┼──────────────┼──────────────┼──────────────┤
  │ mod-donation │ remaining    │ chart        │ ADR-0018..26 │
  │ worldbuff    │ workflows,   │ hardening,   │ AGENTS.md,   │
  │ guildbank    │ lint matrix, │ HPA,         │ issue import │
  │ lft-botfill  │ publish      │ migration    │              │
  │ solo-dungeon │              │ Jobs         │              │
  │ playerbots   │              │              │              │
  │ promotion    │              │              │              │
  └──────────────┴──────────────┴──────────────┴──────────────┘
```

- **Track A modules are independent of each other** — several people can each take one, because each is its own directory, schema, tests and config. The only shared resource is a core hook, and adding one is a separate small PR to `twow-core`.
- **Tracks B and C need only Phase 1's compose file** as their contract, not finished modules. The chart and publish pipeline can be built against a stub image on day one.
- **Track D runs continuously**, not at the end. Each ADR lands with the PR implementing its decision.
- The one genuine cross-track dependency is `mod-playerbots` promotion, which the deferred bot work depends on — schedule it first within Track A.
- Every track rebases on `refactor/modular-platform`, which rebases on `main` at phase boundaries only. Rebasing a fanned-out set of branches mid-phase is where this kind of refactor usually dies.

## Execution mechanics: subagents and parallel issue creation

How the work is actually run, step by step. The rule throughout: **anything that edits `CMakeLists.txt` or git history is serial; everything else fans out.**

### Step 1 — Re-baseline (serial, ~1 call)
Pull `main`, record the HEAD SHA, confirm `3c2b931` is an ancestor, confirm a clean tree and single worktree. FG-072 applies: inventory worktrees before touching anything. Create `refactor/modular-platform` from the verified base.

### Step 2 — Runbook sweep (3 parallel Explore subagents)
`runbooks/` is 1,299 files, so this is partitioned rather than sequential:

| Agent | Partition | Produces |
|---|---|---|
| A | `runbooks/workstreams/**` (307 files, incl. the new OT-001 packages) | open items per workstream, with WS id and evidence path |
| B | LLM bridge + roster phase dirs (`ssc-llm-*`, `rndbot-*`, `ssc-source-baseline-*`) | open items, superseded-vs-live classification |
| C | everything else (donation, shutdown labs, discovery, personality, external-evidence) | open items, plus the disposable/duplicate list |

Each returns a manifest fragment in one shape: `id, title, body, workstream, priority, source-path, superseded-by`. They run **concurrently in a single message**. Their job is classification — separating live open threads from closed evidence — not copying.

### Step 3 — Manifest assembly (serial)
Merge the three fragments with `TODOS.md` (OT-002…OT-026), this plan's deferred work, and your friend's task markdown into `docs/issues/*.md` with YAML frontmatter. Deduplicate by OT id. **You review this file before anything is created** — it's the last human gate before the tracker is written.

### Step 4 — Issue creation (parallel, throttled, idempotent)
Labels and milestones first (serial, ~3 calls: `gh label create` in a loop, `gh api` for milestones). Then issues in **parallel batches of 4–5 concurrent `gh issue create` calls**, not one big loop and not 40 at once — GitHub applies secondary rate limits to content creation, and a burst gets throttled or partially rejected, which is the worst outcome for an import.

Two properties that make this safe to re-run:
- **Idempotent**: each issue carries its manifest id in the title (e.g. `OT-024: …`); the creator queries existing titles first and skips matches. A half-failed run is fixed by running it again.
- **Reversible**: the manifest is the source of truth in Git, so a botched import can be closed in bulk and re-created from the same file.

Sanity check first: the repo is private, issues are enabled, `gh` 2.92 is authenticated with `repo` scope, and there are currently **zero** issues — so this is a clean import with nothing to collide with.

### Step 5 — Phase 0 build/test/CI work (mixed)
Serial, because they all touch the same CMake files: build fixes (§2) → test infrastructure (§3). Then **3 parallel agents**, since these touch disjoint trees: CI workflows (§4, `.github/`), `AGENTS.md` rewrite (§5), smoke tests (§6, `test/smoke/`). Each lands as its own PR.

### Step 6 — Phase 1 (partly parallel)
Dockerfile → compose → `make up` is a serial chain (each depends on the previous). Once the compose file exists it becomes the contract, and **GHCR publishing and the Helm chart run in parallel** against a stub image — neither needs finished modules.

### Step 7 — Phase 2, the upstream split (serial, with parallel prep)
The re-application of 114 files as clean commits is inherently serial. But the **classification is not**: run 2–3 parallel agents beforehand to sort the delta into "upstream bug fix" / "module feature" / "integration hook", producing a reviewed table that drives the commit sequence. That is the expensive analytical part and it parallelizes cleanly.

### Step 8 — Phase 3 (fully parallel)
One agent per module — `mod-donation`, `mod-worldbuff`, `mod-guildbank`, `mod-lft-botfill`, `mod-solo-dungeon` — because each owns its own directory, schema, config and tests. `mod-playerbots` promotion goes **first and alone**, since the others' extraction patterns depend on how the module system ends up being used, and the deferred bot work depends on it.

**Cap concurrency at 3–4 agents.** More than that on a codebase this size produces overlapping edits and conflicting CMake changes faster than it produces progress.

## Issue tracking

Yes, GitHub issues is the right call, and the repo is ready: `gh` 2.92 is authenticated, issues are enabled, and there are currently **zero** issues, default labels only, no milestones. So we're setting up a clean tracker rather than migrating one.

Division of responsibility, which matters more than the tooling:
- **ADRs stay in the repo.** They are decisions of record — permanent, reviewed, versioned with the code. Issues are ephemeral work items. Don't move ADRs into issues.
- **`docs/FOOTGUNS.md` stays** — it's reference material, not work.
- **`docs/OPEN-THREADS.md` becomes issues.** OT-001…OT-022 map one-to-one, keeping the OT id in the title so existing ADR citations still resolve. The file is reduced to a pointer plus the "deliberately separate decisions" prose.

Setup:
- **Labels**: workstream (`ws-00`…`ws-80`, matching the existing hub so the governance model survives), priority (`p0`/`p1`/`p2`, matching OPEN-THREADS), type (`refactor`, `deferred-architecture`, `bug`, `adr`), and track (`track-a`…`track-d`).
- **Milestones**: one per phase, plus `deferred`.
- **Issue templates**: add `task.md`, `adr-proposal.md` and `deferred-design.md` alongside the nine inherited upstream gameplay templates.
- **A Project board** with columns keyed to the tracks, so the parallelization map above is the board.
- **Reproducible import**: the issues are generated from a manifest checked into the repo (`docs/issues/*.md` with frontmatter → `gh issue create`), not hand-created. That way the mapping is reviewable, re-runnable, and doesn't drift from the plan.

For your friend's task list: he drops a markdown file in the repo, it gets the same frontmatter treatment, and imports through the same path — so both sources land as issues with consistent labels rather than two different conventions.

One caveat worth stating: creating issues writes to a shared repo, so the first run happens with your review of the manifest, not silently.

**This plan is the interim record.** Everything discussed in this session — the deferred architecture, the reasoning behind each decision, the measured facts backing them — lives only here until the issues exist. So the very first act of Phase 0 step 7 is to commit this document into the repo (as `docs/issues/00-refactor-plan.md`) and derive the issue manifest from it. Nothing gets deleted from it until the corresponding issue is filed and links back to it.

## Deferred work — to be filed as detailed issues

Each of these gets a full issue with the research already done in this session: the current state, the constraint that makes it hard, the design, the test strategy, and the decision gate. They are written to be picked up cold, months later.

1. **Externalize bot cognition (the "bot brain")**. The split is along the **latency axis**, which is where the real constraint lives:

   | Tier | What runs where | Budget | Verdict |
   |---|---|---|---|
   | 0 | C++ engine in-core (today) | per-tick | stays, becomes the fallback |
   | 1 | **Policy sandbox** — per-tick behavior as sandboxed WASM policies executed *inside* the tick, shipped as data by the brain | per-tick, no network | issue #7 |
   | 2 | **External planner** — slow decisions (what next, grouping, travel, social, chat) over gRPC to stateless pods | 100ms–seconds | this issue |
   | 3 | **External protocol clients** — full headless bot clients | network | issue #8 |

   Tier 1 is the answer to "the per-tick stuff is hard": per-tick decisions never leave the process, but the *behavior* becomes data rather than compiled C++. Tier 2 is where the scaling lives — planning is where the CPU goes at 1000 bots and it parallelizes cleanly across pods.

   **Measured constraint:** 989 files (299 actions, 195 values, 48 triggers) where every node holds a live `Player*`/`Unit*` and reads world state on demand. There is no serializable state to ship, so this is a re-implementation, not a port.

   **Language: Go.** The workload is concurrency- and I/O-bound orchestration (thousands of sessions, protobuf, DB, HTTP to an inference server), not numeric hot loops — Rust's advantage doesn't apply where the bottleneck isn't CPU. Go gives cheap goroutines per bot session, first-class gRPC, static binaries in ~15MB scratch images, sub-second start. The contract is protobuf, so if Tier 1 or 3 ever creates a genuine hot loop out of process, that one component can be Rust behind the same `.proto`.

   **On "stateless":** the services are stateless **per request** — no in-memory bot state between calls — while durable bot state lives in its own schema. That's what makes them horizontally scalable and trivially unit-testable; it is *not* a claim that bots have no state.

   **Testing-first is the strongest argument for the split**, and it drives the sequencing. The snapshot/intent contract is a protobuf schema, which makes it a test seam: unit tests feed a snapshot and assert an intent (no server, no DB, no game); a **mock world server** replays snapshots *recorded from a live server* against the real brain and asserts the intent stream, so fixtures are real game situations rather than invented ones; a **mock brain** of a few hundred lines lets the C++ side be tested with no service running; and contract tests run both directions, failing the build on schema drift. None of that is reachable while the AI is welded to `Player*`. Build the mock harness **before** the real brain.

   **Decision gate:** p99 intent latency, messages/sec at 1000 bots, worldserver CPU delta — proven on one behavior (travel-target / quest selection, chosen because it's slow-cadence and self-contained) before anything else moves. Publish the numbers; pick the next behavior family on evidence.
2. **Bot persona, memory and canon** — the big one you just described. Detailed below.
3. ~~Integrate the persistent roster (OT-001)~~ — **done** in `3c2b931`. Replaced by **OT-024: roster expansion and capacity proof** — extend the proven 50→100 path through 100→250 and 250→500, verifying version persistence, ordering, hashes, restart recovery, retained older versions and failure rollback, and *separately* measuring startup/login/CPU/RAM capacity. Note the handover's own open question: which tests are mandatory at 50/100/250/500 and what measurements define acceptable capacity. Also note `MinRandomBots`/`MaxRandomBots` are not a persistent expansion.
4. **Integrate and re-transport the LLM bridge** (OT-003) — `.../phase-b-r1-20260830-194919/source-copies/`, rewritten from Windows named pipes to a network transport so it works on Linux, keeping the fail-closed admission and world-thread session re-validation the ADRs got right. Port the 683-case suite to gtest.
5. **Inference backend policy** — `llm-gateway` speaking the OpenAI-compatible API with a swappable backend; **vLLM** as production default (published 2026 benchmarks: ~16–20× Ollama's concurrent throughput; at 50 concurrent users p99 ~24.7s vs under 3s), **llama.cpp server** for CPU/small GPU, **Ollama demoted to a dev adapter**. Also: move the model pin out of C++ — `kModel = "qwen2.5:7b"` is currently a compile-time constant in `ExternalLLMBridgeService.cpp:48` beside four hardcoded package hashes.
6. **Bot chat character mangling** — reported backticks arriving as `?`. Undiagnosed. Candidates: the 1024-byte cap and 255-byte chunking in `PlayerbotLLMInterface` (`Utf8PrefixSize`, `SplitUtf8DebugMessage`), `SanitizeForJson`, or a codepage conversion between model output and client chat encoding. Since backticks are single-byte ASCII, UTF-8 truncation doesn't explain them — the codepage path is likelier. Reproduce with a fixture first; add an encoding round-trip test.
7. **WASM policy sandbox** — per-tick behavior as sandboxed policies executed inside the tick, shipped as data by the brain. Only if the brain measurements show the per-tick path is the bottleneck.
8. **Headless protocol bot clients** — your "bots are just remote players" idea, with the entry cost written down: SRP6 auth, encrypted world socket, a client-side world model reconstructed from `SMSG_UPDATE_OBJECT`/movement/spell packets, plus its own navmesh and DBC data. Architecturally right and it's what headless-client load testing does industry-wide; it is a separate product, not a refactor. The snapshot/intent contract from (1) is the same contract a headless client would fill, so nothing blocks it later.
9. ~~Runbook bucket-C cleanup~~ — **settled by OT-026/ADR-0018**: runbooks stay in the main repo for this restructuring; a separate evidence repository is re-evaluated only afterwards, and only with stable identifiers plus link-migration, retention and access contracts. Nothing to do.
10. **Bot behaviour and cohort specification (blocked on input).** The topics named as deferred in the discovery report — GUID-cohort mechanism, grouping lifecycle, spec behaviour, gear scoring, gathering, quest turn-in, profession pairing — have no written specification anywhere in the repo. Issue exists to capture that specification once your collaborator writes it down; do not design against assumptions until then.
11. **Cross-platform canonical-request divergence** (`PersistentActiveRoster.cpp:135-155`) — Windows enforces UTF-8 **plus NFC normalization**, POSIX enforces only UTF-8 well-formedness, so the same admin request can be rejected on one platform and accepted on the other. Given the roster contract is built on canonical bytes and SHA-256 digests, this needs a single shared normalization implementation rather than two. Small, self-contained, and worth doing early since it blocks trustworthy Linux roster administration.
12. **Roster capacity proof (OT-024)** — see the replacement for deferred item 3 above.

### Deferred issue #2 in detail: persona, memory and canon

The audit's headline: **the spec is far ahead of the implementation, and the upstream module already ships a mature canned-text engine nobody connected to the personality work.** So this is much less greenfield than it looks.

**What already exists and should be reused, not rebuilt:**
- `runbooks/personality-context-contract-v1.md` (37,690 B, 559 lines, German, `Arbeitsentwurf 1.0`) — §8 is a **trait instruction catalog of ~120 traits**, each with a label and a one-sentence behavioral instruction. That is the single most valuable asset in the whole persona effort and it only needs translating and extending. §4.1 specifies the deterministic selection exactly: `SHA-256(profile_version | profile_seed | source_type | source_key | trait_key)`, highest stable values win per quota — so results don't depend on any language's RNG. §9 gives duplicate rules (strength = max of origins, never summed; every origin traceable) and six hard conflict pairs with the priority order `locked manual > race variant > class > race > profession`. §10 caps a reply at 3 active traits. §12 whitelists intents (`none`, `invite_request`, `quest_proposal`, `craft_offer`, `guild_event_proposal`) as suggestions with no side effect until the server validates. All specified, none implemented.
- **`ai_playerbot_texts` + `PlayerbotTextMgr` + `ai_playerbot_texts_chance`** — 1,943 rows across 127 keys, 8 locales, probability gating, a placeholder substitution engine, and `LinesToPackets` emitting text with typing-speed delay and emotes. **This is the filler system already built.** The fallback layer should add trait-keyed `name` values to this table rather than invent a parallel renderer. Note the same substitution engine already renders the LLM prompts (`BOT_TEXT2` in `SayAction.cpp:573`), so fillers and generated text share one templating layer for free.
- **`ai_playerbot_db_store`** — the per-bot KV store, with `manual saved string::llmdefaultprompt` already wired end-to-end from a file into the prompt (`PlayerbotAIConfig::LoadLLMDefaultPrompts`). One latent bug to check first: that path writes the **low** GUID from `characters.guid` while `PlayerbotDbStore::Save` uses the **raw** ObjectGuid.
- The bridge's output-side safety (`sanitizeAssistantText`, strict JSON, envelope schemas, model and context SHA pinning) and `ChatReplyAction::GetAIChatPlaceholders` + the 15-value channel-name map as the context builder.

**What genuinely must be built:**
- **Trait assignment.** 0 of 4,500 bots have traits. `bot-personality-mapping-v1.json` (934,830 B) carries race/class/gender for all 4,500 — but `professions` is empty for every bot (0 rows in `character_skills`) and `race_variant_key` is null throughout. So two of the five trait sources in the contract have no data yet.
- **All five personality tables** and their migrations (`ai_personality_traits`, `ai_personality_trait_rules`, `ai_bot_personality`, `ai_bot_traits`, `ai_bot_trait_origins`). None exist.
- **Memory — nothing is persisted.** Conversation context today is a flat `" Name:line"` blob in `AI_VALUE(std::string, "manual string::llmcontext…")`, truncated from the front against `LLMContextLength=4096`. It uses `manual string`, **not** `manual saved string`, so `PlayerbotDbStore::Save` never writes it and **it is lost on every bot logout and server restart.** That directly violates invariant #1 — a bot that forgets everything on restart has not kept its history — so this is the load-bearing piece.
- **Canon — nothing exists.** The contract's stance is actually *anti*-canon: bots may not invent history, relationships or a past, and every real fact must come from supplied context. Defining a positive canon (setting, era, allowed registers, faction lore, glossary) is new work.
- The bridge is **hard-pinned to one bot** (GUID 18281) and one profile file, so multi-bot is unbuilt. The German contract (§11.1 "Standardmäßig Deutsch") and the English-only shipped `fixed_system_instruction` are an unreconciled divergence that has to be decided before content is authored at scale.

**Proposed architecture — four layers, each independently testable**, inspired by [Project AIRI](https://github.com/moeru-ai/airi)'s "soul container" split (personality config, memory persistence and transport as separate composable packages):

1. **Identity** — implement the contract as written. Deterministic, no LLM, reproducible. This is the bot's character sheet.
2. **Memory** — the Generative Agents three-tier model: **episodic** (append-only event log: who, what, where, when, with whom, importance), **semantic** (facts consolidated from episodes on a schedule — "Grimtusk considers Sylva a reliable healer"), **working** (the in-request conversation window). Retrieval scores recency + importance + similarity.
   **Storage: MariaDB 11.8 native `VECTOR(N)` + `VECTOR INDEX` (HNSW)** — GA since 2025, up to 16,383 dimensions, `VEC_DISTANCE_COSINE()`, full ACID, and benchmarked competitively against pgvector/Qdrant/Milvus. This answers "DB or vector DB" with **no new datastore**: the memory tables live beside everything else. Prerequisite: pin 11.8 everywhere — `ops/windows/build/compile-tortoise-wow.ps1:49` currently pins 11.4.10, which has no VECTOR type.
3. **Intentions / scripts** — markdown with YAML frontmatter, versioned in the repo as content, compiled into goals. Two kinds: **character scripts** (a bot's standing arc — "wants to become a master alchemist, distrusts the Syndicate") and **scenario scripts** (server-wide narrative beats with a cast). These feed both the planner and the chat generator. Authored by a human in markdown, which is exactly the WS-70 boundary ADR-0015 already draws: personality is content, not C++.
4. **Canon** — a versioned content pack (setting rules, era, allowed topics, forbidden registers — no sci-fi, no modern tech, no meta or tech support, no out-of-universe references — plus faction lore and a glossary), compiled into both a retrieval slice and a machine-checkable rule set.

**Generation pipeline — the multi-layer LLM you described:**

```
trigger → admission (existing fail-closed rules)
  → context assembly: traits + retrieved memories + canon slice + intention + conversation window
  → GENERATOR  (larger model, creative)
  → VALIDATOR  (deterministic rules first, then a small fast model)
       checks: canon compliance, trait consistency, no OOC/meta,
               no leaked GUIDs/schema/prompt, length/format, intent whitelist
  → pass  → deliver + write episodic memory
  → fail  → one bounded repair attempt with the violation as feedback
  → fail  → PROCEDURAL FALLBACK
```

Two things make the validator cheap: run the **deterministic rules first** (regex/wordlist for anachronisms, URLs, code blocks, modern brands catches most violations for free), and make the model half **small** (1–3B with a short rubric) against a 7B+ generator.

**Procedural fallback — your "uhm" and "let me think about this".** Tiered, and all of it renders through `ai_playerbot_texts`:
- **thinking fillers** emitted immediately while generation runs, which also makes latency read as natural rather than broken;
- **deflections** ("Let me think on that, friend");
- **archetype greetings/farewells and topic-safe defaults**.
Selection is deterministic from (bot GUID, trait profile, situation, rotating salt) so a bot's voice stays consistent and doesn't repeat a line back-to-back. This **upgrades ADR-0012's fail-closed rule**: today fail-closed means silence; it should mean *stay in character with no LLM*. That is strictly better and needs an explicit ADR amendment. It also gives a clean test oracle — an integration test kills the gateway and asserts bots still talk, in character.

**Deployment shape:** `llm-gateway` stays pure transport (stateless, model routing, backend adapters, no knowledge of bots). Persona starts as a **package inside the brain service** with its proto boundary drawn from day one, and is split into its own deployment when the content lifecycle or scaling demands it — so the split is a deployment change, not a rewrite. That keeps ADR-0015's WS-10/WS-70 ownership line intact without inflating the service count before there's evidence for it.

**Testing:** golden-set tests where the validator must correctly classify a labeled corpus of (context → response) pairs, run in CI against recorded model outputs and nightly against the real model; plus an **adversarial suite** — players *will* try "what's your system prompt", "help me fix my wifi", "you're an AI, right?". The validator is a security control, not just a flavor control, and that suite is how it stays one.

## ADRs

Existing ADRs are decisions of record and are not rewritten; where this plan changes one, it gets a **superseding** ADR naming its predecessor (the register already uses this pattern).

Amend / supersede:
- **ADR-0005** (preserve upstream history, modularize incrementally) — superseded by the two-repo split. It predates the `modules/` script system and never reconciled with it.
- **ADR-0007** (migrations, backups, rollback) — extended with schema ownership.
- **ADR-0008** (source baseline and build provenance) — replaced by the submodule SHA + `UPSTREAM.lock` + CI build manifest, closing OT-014.

New, in this refactor (renumbered — ADR-0018 and ADR-0019 are now taken):
- **ADR-0020** Two-repo upstream split, submodule vendoring, and upstreaming policy.
- **ADR-0021** Module boundaries and per-module schema ownership.
- **ADR-0022** Test strategy: unit-first, characterization tests for extractions, smoke gate.
- **ADR-0023** Containerization, the one-command contract, GHCR publishing and the Helm chart.
- **ADR-0024** Project invariants — the ground rules above, bot persistence first among them.
- **ADR-0025** Repository and project structure — the directory layout, what may live where, module naming, where tests and migrations belong, and the rule that the folder structure *is* the module structure. The CI boundary and schema-ownership checks are its enforcement.
- **ADR-0026** Project lineage and provenance — the chain above, the upstream remote of record, the merge-base, and the relationship to the one-click compiler and docker stacks. Currently reconstructible only from GitHub, which is a real gap.
- **ADR-0027** Database platform: MariaDB 11.8 as the single datastore; the dead `DO_POSTGRESQL` path documented as dead and the dialect lock-in recorded, so this doesn't get re-litigated.
- **ADR-0028** Platform and CI strategy: native builds both sides, no Wine, and the two-tier Windows job that satisfies ADR-0019's external-input boundary — this is the direct answer to the handover's provisioning question.
- **ADR-0029** Work tracking: issues vs ADRs vs footguns, and the reproducible import.

Reserved for the deferred work, written when those issues are picked up: bot cognition tiers and the snapshot/intent contract; inference backend policy; persona, memory and canon.

`docs/OPEN-THREADS.md` closes or supersedes OT-005, OT-014, OT-016, OT-018, OT-019, OT-021, OT-022 in this refactor; OT-001, OT-003 and the rest become deferred issues.

## AGENTS.md

I verified it rather than assuming. **The governance half is intact and currently satisfiable**: the hub exists at `runbooks/workstreams`, and I re-hashed five of the eleven manifest payloads (`canonical-workstream-registry-v1.json`, the hub README, three WS READMEs) — all match `sha256-manifest.txt`. The mandatory preflight in §3.2 passes today, and `docs/history/AGENTS.local-snapshot.md` correctly preserves the local original while `AGENTS.md` is the path-rewritten portable form.

What's wrong with it for where the project is going:

1. **It is 100% governance and 0% engineering.** It tells an agent to read the hub, but never how to build, test, lint or run anything, and never where code lives. It's the file an agent reads first and it currently cannot answer "how do I run the tests".
2. **It predates the structure this plan creates** — nothing about `modules/`, `core/` as a submodule, the branch, or the invariants.
3. **Windows path separators** (`runbooks\workstreams`) while claiming repo-relative paths — wrong on Linux CI and in containers.
4. **§3.5 gates part of this plan.** Modifying hub files or existing runbook artifacts requires an explicitly authorized task, and any change invalidates `sha256-manifest.txt`. That's OT-019, still open. So anything touching runbooks is done as **additive** commits (which §3.5 permits), and hub metadata updates are a separate authorized task — not smuggled into a code PR.

Deliverable: rewritten in Phase 0, governance intact, engineering section added (build/test/lint/run commands, directory map pointing at ADR-0025, the invariants, branch policy), paths normalized. Hub-touching parts wait for OT-019.

## Runbooks

**Do not rewrite history.** FG-006 exists precisely for this: a second filter-repo pass would change every descendant commit identity and invalidate the provenance the ADRs rest on.

One correction worth stating plainly: the **commit history was not reconstructed from the runbooks**. The git history is genuine upstream + fork development history (559 filtered commits). What *was* reconstructed from the runbooks is the **ADRs** (commit `88d711f`, 20 files, 766 lines, sourced from chats and runbooks per `docs/adr/SOURCES.md`). So the ADRs are the distillation — but the runbooks also hold things that never became commits, most importantly the `source-copies/` trees the deferred roster and bridge issues depend on.

**They cannot be dropped wholesale.** The audit found ~3,000 lines of C++ implementation plus test code existing nowhere else, for two accepted ADRs. ADR-0013 inlines the lifecycle constants but the field-level envelope definitions exist only in `bridge-contract-v1.json`; ADR-0010 inlines the roster semantics but the 50-GUID snapshot exists only in `proposal-50-a552de67342df740/`. And 46 distinct runbook paths are cited from `docs/` and `AGENTS.md`, including real relative links in `OPEN-THREADS.md` that would 404.

- **(A) Promote to real code — ~2.5 MB.** Input to the deferred roster/bridge issues, not to this refactor. Authoritative copies (each has older superseded siblings): the roster `phase-b-r2-20260831-131938/source-copies/`, the bridge `phase-b-r1-20260830-194919/{source-copies,tests}/` (including `evidence/full-git-diff.patch`), the Node package under `ssc-llm-bridge-v1-english-correction-20260830-131349/bridge/`, and `bridge-contract-v1.json` + `personality-context-contract-v1.md` → `docs/contracts/`.
- **(B) Keep as archive — ~6.5 MB.** `runbooks/workstreams/` (mandatory under `AGENTS.md` §3.2), the 46 doc-cited reports, `external-evidence/`.
- **(C) Droppable — ~15 MB**, with the honest caveat: **a plain `rm` frees 0 MB of clone size.** `runbooks/` is tracked across 3 import commits; `.git` is 117 MB and keeps every blob regardless. Deleting buys working-tree cleanliness, not repo weight — and repo weight is already solved by moving `sql/` out (58% of the pack). So bucket C is optional, low-priority, and policy-gated by §3.5. Filed as a deferred issue, not done here.

## Verification

Added in Phase 0 so later phases have something to fail against.

| Level | What | How |
|---|---|---|
| Unit (C++) | module logic, hook behavior, config parsing | `ctest`, gtest, no DB, no server — the bulk of coverage lives here |
| Characterization | extracted features behave identically to the spliced originals | written *before* each extraction in Phase 3 |
| Integration | migrations apply cleanly from empty; module tables land in the right schema | compose-driven, ephemeral MariaDB, in CI |
| Smoke | is it alive: ports, migrations count, bot login, clean shutdown, bot persistence across restart | `make smoke`, local + CI, the gate for every phase |
| Lint | everything non-compiling, incl. boundary and schema-ownership rules | `lint.yml` |

End-to-end acceptance, the thing that says this worked:

```bash
git clone --recursive <repo> && cd twow-repo
make up          # db, migrations, realmd, worldserver
make smoke       # all green, including bot persistence across a restart
make test        # unit + integration
```

with client data the only manual prerequisite, and the same three commands working on Windows via `ops\*.ps1`.

---

# Status — updated 2026-09-01

Work landed on `refactor/modular-platform`. Measured results, not estimates.

## Done

**Phase A — foundations.** `ctest` runs real tests for the first time: 2 suites,
565 gtest assertions plus 142 roster checks, 34s to build cold and 0.09s to run,
verified in a Debian 13 container. CI went from 19 job entries and ~5 full
compiles per push to 5 entries and 1 compile, in one `ci.yml` with a job DAG.
All five first-run CI failures fixed, including a `.gitignore` `*.core` pattern
that had silently kept `deploy/docker/Dockerfile.core` out of the repository
entirely.

**Phase B — module framework.** Module slots are claimed by name at runtime, so
adding a module no longer edits a header that rebuilds 82% of the tree. CI
rejects a module that mutates the shared `modules` target. A new module
directory no longer needs a manual cmake re-run. Two stale references fixed: an
include path to a directory the fork deleted, and a dynamic target name that
could never match.

**Phase C — feature extraction.** Four features left the core:
`mod-donation`, `mod-worldbuff`, `mod-leech`, `mod-solo-dungeon`. They were
inline in `World::Update()`, `Unit::DealDamage()` and
`Player::RepopAtGraveyard()` with no file of their own. Two core seams were
added for them, each justified: `ShopMgr::AwardCoins` so a module credits the
shop without owning its table, and `UNITHOOK_ON_DAMAGE_APPLIED` because the
existing damage hook fires before modifiers that leech must see.
`PLAYERHOOK_ON_REPOP_AT_GRAVEYARD` is a veto hook, since solo-dungeon repop has
to pre-empt the core rather than react to it.

**Phase F — handover rules.** `AGENTS.md` carries the issue workflow and the
parallel-agent ownership rules.

## Corrections to this plan, found by doing it

**"48 of 54 tests are hermetic" was wrong.** That measured the *test files'*
include closure, but a test binary also compiles the module sources it links,
and ten of those reach `Player.h`/`Map.h`/`PlayerbotAI.h`. The real core-free
set is 30 test TUs, found empirically rather than guessed.

**"Extracting features shrinks the core delta" was wrong.** Only 6 of 125
changed files are feature-only. The delta is dominated by a compatibility shim —
1,074 added lines across the main headers — and it **cannot move module-side**,
because it is member functions on core classes and a module cannot add members
to a core class. Recorded in ADR-0020. This does not undermine the split: the
shim is *additive* and merges cleanly, whereas the interleaved feature code was
the thing that actually hurt, and that is now gone.

## Not done, specified as issues

- **REF-009** promote playerbots to a module. Large (989 files) and carries a
  design correction: promote it *static-only* rather than removing the link-time
  stubs first, because six of those symbols are diagnostic probes not worth six
  core hooks, and dynamic linkage was never viable for it anyway.
- **REF-003** the upstream split. Size it by the 33 upstream-worthy fixes, not
  by file count — see the ADR-0020 spike.
- **REF-007** LFT bot fill: deliberately not extracted, with reasons.
- **REF-008** four unexplained fork changes needing a decision, one of them a
  2FA setting.
