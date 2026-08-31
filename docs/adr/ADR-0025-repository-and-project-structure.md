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
