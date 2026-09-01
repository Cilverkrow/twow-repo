# ADR-0025: Repository and project structure

- Status: Proposed
- Date: 2026-09-01
- Primary: WS-00 / WS-80
- Relates to: ADR-0020 (two-repo split), ADR-0021 (module boundaries), ADR-0018 (runbook retention), ADR-0028 (Windows is compile-only)

## Context

The repository is one merged tree in which upstream code, fork fixes, fork features and
governance evidence are indistinguishable. Nothing states where a new file belongs, so
new work lands wherever the nearest existing file sits — which is how three fork features
ended up spliced into `World::Update()` and the spell pipeline with no file of their own,
and how a second module system grew under `src/modules/PlayerBots`.

A layout that is only described in a plan is a suggestion. To be binding it has to be
recorded and checked.

## Decision

**Folder structure is module structure.** A feature's directory is its boundary: its
code, config, migrations and tests live inside it, and nothing of it lives outside.

```
twow-repo/                     the platform
├── core/                      → submodule: twow-core @ pinned SHA
├── core-patches/              generated review artifact (0001-*.patch), never hand-edited
├── modules/
│   ├── mod-playerbots/        src/  conf/  data/sql/  t/
│   ├── mod-dungeon-clear/     (already shaped this way)
│   ├── mod-donation/  mod-worldbuff/  mod-guildbank/
│   ├── mod-lft-botfill/  mod-solo-dungeon/
├── deploy/
│   ├── docker/                Dockerfile.core, entrypoints
│   ├── compose/               docker-compose.yml + profiles
│   └── helm/twow/             chart
├── test/
│   ├── unit/  integration/  smoke/
├── docs/                      ADRs, footguns, contracts, issues
├── ops/                       build and run helpers
└── sql/                       only SQL we author
```

Rules:

- **Modules are named `mod-*`** and live only under `modules/`. Inside each:
  `src/` (code), `conf/` (its own `.conf`), `data/sql/{auth,character,world}/` (its
  migrations, which `AutoUpdater.cpp` already discovers), `t/` (its tests). A module
  never writes a schema it does not own (ADR-0021).
- **`core/` is a submodule**, pinned by SHA, with `UPSTREAM.lock` recording the URL,
  the pinned SHA and the merge-base. Clones need `--recursive`.
- **`core-patches/` is a generated artifact**, produced in CI from `twow-core`'s branch so
  a reviewer can see the whole core delta at a glance. The source of truth is commits in
  `twow-core`, never these files.
- **`test/`** holds cross-cutting suites — integration and smoke against the running
  stack. Per-module unit tests stay in the module's `t/`.
- **`sql/`** keeps only SQL this project authors. `sql/base`, `sql/database_updates` and
  `sql/create_databases.sql` move to `twow-core` in Phase 2: 188 MiB across 336 files,
  9 commits ever, all upstream authors.
- **`docs/issues/`** holds the reviewable issue manifests (ADR-0029); `docs/adr/` the
  decisions; `docs/FOOTGUNS.md` the reference material.
- **`ops/`** holds build and run helpers. `ops/windows/**` is **retained as historical
  evidence and for the existing live server, but is not extended** (ADR-0028); new
  operational tooling is written for Linux and containers.
- **`services/` is deferred.** It is not part of this refactor and no directory is created
  for it; the same applies to `test/fixtures/snapshots/`. They arrive with the deferred
  architecture work, if at all.

**Enforcement is CI, not convention** (`.github/workflows/lint.yml`):

- a **boundary check** failing any pull request that touches `core/` without the
  `core-change` label, so a core edit is always a deliberate, separately reviewed act;
- a **schema-ownership check** rejecting a module migration that names an upstream schema
  (ADR-0024 invariant 2);
- the binary/size gate and `gitleaks` (ADR-0004, invariant 5).

## Consequences

- "Where does this go?" has one answer, and a reviewer can reject a placement by citing
  this ADR rather than taste.
- Repository weight resolves as a side effect: SQL is ~58% of the pack and leaves with
  upstream. Deleting tracked files frees no clone size — the history keeps every blob —
  so the split is the only measure that actually shrinks it.
- Requiring `--recursive` is a real onboarding cost and a real failure mode; the one-command
  contract (ADR-0023) has to absorb it.
- Some existing paths are wrong under this layout and are moved by the phases, not by this
  ADR: `src/game/LFT/LFTBotFill.cpp` and `src/modules/PlayerBots/`.
- `AGENTS.md` currently uses Windows path separators while claiming repository-relative
  paths, which breaks in Linux CI and containers. Its rewrite points at this ADR for the
  directory map.
- Changes touching `runbooks/` remain gated by `AGENTS.md` §3.5 and OT-019, so runbook
  reorganisation is out of scope here (ADR-0018).

## Evidence

- `docs/issues/00-refactor-plan.md` ("Target structure", Phases 2 and 3)
- `cmake/ConfigureModules.cmake`, `modules/create_module.sh`, `modules/mod-dungeon-clear/`
- `src/shared/Database/AutoUpdater.cpp` (`ProcessModuleUpdates`)
- `.github/workflows/lint.yml`
- `docs/adr/ADR-0020-two-repo-upstream-split.md`, `ADR-0024-project-invariants.md`,
  `ADR-0028-platform-and-ci-strategy.md`
- `docs/REPOSITORY-BOUNDARIES.md`, `docs/PROVENANCE.md`

## Update 2026-09-01: the promotion happened

`src/modules/PlayerBots` is `modules/mod-playerbots`, and `BUILD_PLAYERBOTS` is gone.
`src/modules/` no longer exists; every module lives under `modules/`.

Two things came out differently from what was written above:

- **Static only**, and not because C++ forbids the alternative. The decisive reason is
  that the core's seam is resolved by the *linker*: `game.a` calls eleven free
  functions, and `PlayerbotStubs.cpp` supplies no-ops whenever the module is off, so a
  `.so` would leave the core calling the stubs — a server with no bots and no error.
  Two more reasons stack on top: the framework cannot express that
  `mod-dungeon-clear` depends on this module (dlopen is `RTLD_GLOBAL`, so on Linux it
  would resolve only if load order happened to be right), and a Windows DLL exports
  nothing the vendored tree has not marked, which it has not.
  `mod-playerbots.cmake` refuses dynamic linkage with that reason rather than failing
  at link time.
- **The link-time seam stays.** The plan called for deleting
  `src/game/PlayerbotStubs.cpp` first. Six of its eleven symbols are `BotActionLog_*`
  diagnostic probes called from twelve sites in `Unit.cpp` and `Spell.cpp`; six new
  entries in `ScriptObjects.h` to relocate logging is a bad trade, and dynamic linkage
  — the only reason the stubs were a blocker — was never available anyway.

The payoff landed as expected: `mod-dungeon-clear` dropped 25 hand-written include
directories, because `CollectModuleIncludeDirectories` now publishes them and linking
the target carries them across.

## Update 2026-09-01: `core/` exists, and what "folder structure is module structure" now means for the build

The submodule is in at `core/`, on the branch that was `tortoise` when ADR-0020 was
drafted and is `main` since 2026-09-01. Three things about the layout above changed
in contact with the build, and two of them are traps rather than preferences.

**`core/` was ignored by `.gitignore`.** The core-dump rule was a bare `core`, and a
bare pattern matches a directory exactly as well as a file. `git submodule add core`
was refused outright, and had it been forced without noticing, `git status` would have
reported nothing about the submodule from then on. The rule now carries a `!/core/`
negation directly under it. This is the second time that same line has caused a silent
omission — it previously matched `deploy/docker/Dockerfile.core` under a `*.core`
spelling and kept the Dockerfile out of the repository entirely.

**`.dockerignore` patterns are anchored, so the split reopened a hole it had closed.**
`sql/` excluded 130 MB of upstream world data from the build context. That data moves
to the core, and `sql/` does not match `core/sql/`, so the context silently grew back
by the exact amount that entry exists to prevent. Both are named now. Anything added
to `.dockerignore` from here has to be checked against the core tree as well as this
one.

**The build is now inverted, and the order is load-bearing.** This repository's root
`CMakeLists.txt` is the top-level project; `core/` is a subdirectory of it. The
sequence is: discover modules (directory globbing only), hand the core three input
variables, `add_subdirectory(core)`, **re-apply the core's compile settings at this
scope**, `add_subdirectory(modules)`, then attach `modules` to the core's
`tw_core_extensions` seam. ADR-0020's update records why each step is where it is.

The step that reads as redundant and is not is the re-application. CMake directory
properties are inherited by *children*, and under this layout `modules/` is a
**sibling** of `core/`. Skip it and every module translation unit compiles core
headers without `DO_MYSQL`, without `SYSCONFDIR`, and — the dangerous one, because it
links cleanly — without `DT_VIRTUAL_QUERYFILTER`, which decides whether
`dtQueryFilter::getCost` is virtual. A module whose navigation filter is never called
is not a build failure; it is a bug report six weeks later.

So the rule the directory map implies has a build counterpart worth stating outright:

- **A module names core paths through `TW_CORE_ROOT`, never relatively and never
  through `CMAKE_SOURCE_DIR`.** The core publishes it as a `CACHE INTERNAL` entry
  because sibling directories inherit nothing. `modules/CMakeLists.txt`'s
  `MODULES_COMMON_INCLUDES`, `mod-playerbots.cmake` and both `tests.cmake` files were
  converted; `${CMAKE_SOURCE_DIR}/modules/...` inside a module is still correct and
  was deliberately left alone.
- **The core never names a module.** `src/game/CMakeLists.txt` and
  `src/mangosd/CMakeLists.txt` both called
  `GetModuleEffectiveLinkage("mod-playerbots" ...)` — the core reaching into the
  module framework to ask about one of our modules by name. Those are core options
  now (`TW_EXTERNAL_PLAYERBOT_HOOKS`, `TW_EXTERNAL_MODULE_LOADER`), and the Windows
  Boost link-directory hunt that sat in `src/mangosd` moved into
  `mod-playerbots.cmake`, where the dependency actually originates.

**Still not done, and deliberately so:** the duplicated core files under `src/`,
`dep/`, `cmake/`, `tools/` and `sql/base` are still present in this repository. They
are byte-identical to the submodule apart from a handful of header self-containment
fixes that exist here and not yet in `twow-core`. Deleting them before those fixes are
committed upstream in the core would lose them. The enforcement checks this ADR
specifies (`lint.yml`'s boundary check on `core/`) also do not exist yet.
