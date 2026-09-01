# ADR-0020: Split upstream and project code across two repositories

- Status: Proposed
- Date: 2026-08-31
- Primary: WS-00 / WS-10 / WS-50
- Supersedes: the "keep one tree" half of ADR-0005

## Context

Upstream code and project code are currently indistinguishable in one tree. Measured
against the fork point, 114 core files differ (+5,246 / −1,809), and the
differences are concentrated in the highest-traffic upstream files: `Player.h/.cpp`,
`World.h/.cpp`, `Unit.h/.cpp`, `WorldSession.cpp`, `CharacterHandler.cpp`.

Three project features — `AutoWorldBuff`, `AutoDonationPoints` and
`SoloDungeonRepop`/`Leech` — have no file of their own at all. They live inside
`World::Update()` and the spell pipeline, marked only by `// custom:` comments.

Two consequences follow. Every upstream merge is a manual conflict resolution in the
files that change most often upstream. And the fork's genuinely upstream-worthy bug
fixes — the restored `BattleGroundQueue` mutex, the null anticheat pointer on bot
sessions, the `Unit::DealDamage` branch, the inverted `Engine::Init` flag, the
`vfprintf` format-string abort, the dangling `ownerAura` in Healing Touch — cannot be
offered upstream in that shape, so the fork carries them forever.

The repository's history was rewritten with `git-filter-repo` to strip binaries
(`docs/PROVENANCE.md`), so it can no longer share history with upstream. FG-006
forbids a second rewrite.

## Decision

Split into two repositories joined by a submodule.

**`twow-core`** is a genuine fork of `Shyalya/tortoise-wow`, cloned fresh so it shares
real history with upstream and `git pull upstream` is an ordinary operation. The
project's core delta is re-applied there as small, single-purpose, individually
reviewable commits, each classified as either an upstream-worthy fix or an integration
hook a module needs. Upstream-worthy fixes are ordered first so they can be offered as
pull requests immediately.

**`twow-repo`** — this repository — becomes the platform: modules, deployment, docs,
tests and project-authored SQL. It references `twow-core` as a submodule pinned by
commit SHA, recorded in `UPSTREAM.lock` alongside the upstream URL and the merge-base.

Feature code currently spliced into upstream files is **not** re-applied to
`twow-core`. It becomes modules under `modules/mod-*`.

`core-patches/` is retained as a generated review artifact: the numbered patch series
produced from `twow-core`'s branch in CI, so a reviewer can read the whole core delta
at a glance. The source of truth is the commits, not the files.

Upstream's world data (`sql/base`, `sql/database_updates`, `sql/create_databases.sql`)
moves to `twow-core`. It is upstream's content: 190 files, 130.2 MiB, nine commits ever,
all by upstream authors.

## Alternatives rejected

- **Subtree instead of submodule.** Normal clones and `git subtree push` are
  attractive, but the binary-stripping rewrite means there is no shared history to
  merge against, and subtree merges are harder to review at this delta size.
- **In-repo `vendor/` directory.** Simplest to clone, but it is vendoring by another
  name: it gives no path for sending fixes upstream, which is a primary goal.
- **Pure patch series (quilt-style).** Maximum upstream cleanliness, but every rebase
  touches every patch, and large new subsystems do not fit the model.

## Spike result: the compat shim stays in core

The plan assumed most of the core delta could move module-side, using the pattern
`modules/mod-dungeon-clear/src/AcCompat.h` already demonstrates. **Measured, it cannot.**

The delta is dominated by a compatibility shim that gives Penqle's classes cmangos and
AzerothCore names so the vendored playerbots tree compiles unmodified. Across the main
shim headers that is 1,074 added lines, and they are overwhelmingly **member functions
and in-struct field aliases on core types**:

| header | added | inside a type |
|---|---|---|
| `Player.h` | 340 | 305 |
| `Unit.h` | 151 | 151 (all of it) |
| `Map.h` | 144 | 123 |
| `SharedDefines.h` | 106 | in-struct unions and enum values |
| `Object.h` | 91 | 88 |
| `Creature.h` | 91 | in-struct unions |
| `DBCStructure.h` | 48 | in-struct unions |

A module cannot add a member to a core class. `AcCompat.h` works because it maps *names
and free functions*; it cannot supply `Unit::GetHealthPct()`. So the shim is not
relocatable, and the core delta against upstream will stay roughly this size.

**This does not undermine the decision, because delta size was never the real cost.**
The shim is *additive*: declarations appended inside a class body, which merge cleanly.
What made merges painful was feature code *interleaved* into the middle of
`World::Update()`, `Unit::DealDamage()` and `Player::RepopAtGraveyard()` — and that is
gone, extracted into modules.

So the value of the split is what it always mainly was: a history that lets our fixes be
offered upstream. Expect the shim to remain, and size the work by the 33 upstream-worthy
fixes rather than by the file count.

If the shim is ever to shrink, the lever is the vendored tree, not the core: patching
`src/modules/PlayerBots` to use Penqle's names moves the compatibility burden to where
the incompatibility actually is. That trades merge pain with upstream for merge pain with
ike3, and 255 vendor files are already modified — a separate decision, not a prerequisite.

## Consequences

- Clones need `--recursive`; CI needs recursive checkout. This is the main cost.
- Upstream merges happen in a repository whose history matches upstream, so conflicts
  are ordinary rather than structural.
- Our fixes become offerable upstream, which reduces the long-term carry.
- Repository weight resolves as a side effect: SQL is roughly 58% of the 115.65 MiB
  pack, and it leaves with upstream.
- A pinned SHA plus `UPSTREAM.lock` plus a CI build manifest gives the build provenance
  OT-014 requires, replacing the embedded short revision that ADR-0008 correctly
  refuses to treat as proof.
- The tested OT-001 roster baseline `3c2b931` must be preserved through the split and
  not rewritten (`TODOS.md` guardrail, FG-072).

## Evidence

- `docs/PROVENANCE.md`, `docs/FOOTGUNS.md` (FG-005, FG-006, FG-007, FG-072)
- `docs/adr/ADR-0005-preserve-upstream-history-and-modularize-incrementally.md`
- `docs/adr/ADR-0008-source-baseline-and-build-provenance.md`
- `docs/issues/00-refactor-plan.md`

## Correction 2026-09-01: the fork point, correctly identified

This ADR called `db5fb2a` "the upstream tip". **It is not an upstream hash.** It is a
commit in *this* repository — a post-`git-filter-repo` hash — so `git fetch upstream
db5fb2a` fails, and so does every other attempt to reach it from upstream. It is
absent from all eleven branches of `Shyalya/tortoise-wow`.

The real upstream commit is **`61a8269`**, "Merge pull request #404 from
Penqle/1181dev", with an identical author date. The mapping is confirmed by content,
not by hash: every file under `src/game` is byte-identical between the two. The only
difference is the 146 warden `.cr`/`.key` binaries that `git-filter-repo` stripped
from this repository — which `twow-core`, as a genuine fork, gets back.

`twow-core` is branched from `61a8269`.

Two facts measured at the same time, both of which enlarge the job:

- Upstream has moved **379 commits** since the fork point: 1,178 files,
  +851,023 lines, most of it vendoring the Eluna Lua engine.
- Upstream now carries **its own copy of the bot tree** at `src/modules/PlayerBots`,
  the path this project vacated by promoting it to `modules/mod-playerbots`. Two
  divergent copies of ike3's tree is a collision that needs deciding before the
  first upstream merge — see REF-016.

## Update 2026-09-01: the submodule is in, and where the build seam ended up

`core/` exists. It is `Cilverkrow/twow-core` pinned by SHA, tracking the branch that
was called `tortoise` while this ADR was drafted and is called `main` since
2026-09-01. `UPSTREAM.lock` at this repository's root records the pinned SHA, the
branch, the upstream URL and the corrected merge-base, as POSIX shell assignments
because `nightly.yml` sources the file directly.

`.gitignore` had to be changed before `git submodule add` would work at all. The
core-dump rule was a bare `core`, which matches a directory as happily as a file, so
the submodule path was ignored outright — `git submodule add` refused it and every
later `git status` would have pretended the submodule was not there. A `!/core/`
negation sits under it now.

### The question this ADR left open: what does the core export?

**Decided: the core exports its libraries, its headers, and one INTERFACE target;
the platform owns everything that knows the word "module".**

The core's acceptance test is `cmake -S core -B build` with no `modules/` anywhere on
disk, and it passes. What used to make that impossible was not one thing but five,
and it is worth listing them because "move the module framework out" sounds like a
single edit and is not:

1. `include(ConfigureModules)` and `ConfigureModuleBuildOptions()` at the top of the
   core's root, defining the `MODULES` cache variable and globbing `modules/*`.
2. `add_subdirectory(modules)` and `target_link_libraries(mangosd modules)`.
3. Five compile definitions — `TW_SOURCE_MODULES_DIR`, `TW_MODULE_CONFIG_LIST`,
   `TW_ENABLED_MODULES`, `TW_DYNAMIC_MODULES`, `TW_DYNAMIC_MODULES_INSTALL_DIR` —
   computed from the module list and consumed by `AutoUpdater.cpp`, `Config.cpp` and
   `DynamicModules.cpp`.
4. `src/mangosd/DynamicModules.cpp` calling `AddModulesScripts()`, whose only
   definition was generated by the module framework.
5. **`src/game/CMakeLists.txt` and `src/mangosd/CMakeLists.txt` calling
   `GetModuleEffectiveLinkage("mod-playerbots" ...)`.** This is the one that was not
   in the plan. The core did not merely host the framework; two of its own
   directories asked the framework a question about one named module of ours.

The seam that replaces them:

- **Inputs the core reads, all defaulting to "nothing is attached":**
  `TW_EXT_SOURCE_MODULES_DIR`, `TW_EXT_MODULE_CONFIG_LIST`, `TW_EXT_ENABLED_MODULES`.
  These three are consumed while `core/src/shared` configures, so they must be set
  before `add_subdirectory(core)` — which is possible because all three are
  answerable by globbing a directory, with no target involved. That is why the
  platform root runs module *discovery* first and module *target creation* last.
- **`tw_core_extensions`, an INTERFACE library** the core creates and links into
  `mangosd`. The platform populates it after the fact with the `modules` library and
  the three `TW_DYNAMIC_MODULES*` macros.
- **Two options standing in for symbols the core references but need not define:**
  `TW_EXTERNAL_MODULE_LOADER` (else `ModulesScriptLoaderStub.cpp` supplies an empty
  `AddModulesScripts()`) and `TW_EXTERNAL_PLAYERBOT_HOOKS` (else `PlayerbotStubs.cpp`
  supplies the eleven no-ops, as it already did). The second replaces the
  `GetModuleEffectiveLinkage` calls: the core's real question is "is somebody else
  defining these symbols", not "is mod-playerbots enabled", and the narrower question
  is the one that does not require a framework to answer.
- **`TW_CORE_ROOT` / `TW_CORE_BINARY_DIR`, `CACHE INTERNAL`.** Every
  `${CMAKE_SOURCE_DIR}/src` and `${CMAKE_SOURCE_DIR}/dep` in the core — 133 of them —
  became `${TW_CORE_ROOT}/...`, and so did the ~30 in `modules/CMakeLists.txt`'s
  `MODULES_COMMON_INCLUDES`. `CACHE INTERNAL` rather than a plain variable because
  `modules/` is a **sibling** of `core/`, not a child, and inherits nothing from it.
  The output and install locations (`bin/`, `lib/`, the in-source-build check)
  deliberately keep `CMAKE_SOURCE_DIR`: those belong to whoever is driving the build.

### Why an INTERFACE target and not a cache variable

The obvious alternative — `set(TW_EXTRA_MANGOSD_LIBRARIES ...)` and have the core
link whatever is named — was rejected because a library list carries no usage
requirements, and libraries are not all the platform has to inject. It also has to
put three compile definitions on `mangosd`'s own translation units and, on Windows, a
Boost link directory on its link line. Each of those needs a companion variable, and
every one of them is order-dependent: it must be set before the core reaches
`add_subdirectory(src)`. An INTERFACE target has one property CMake already gives it
that no variable does — it can be populated from another directory *after* the
consumer has been created, because usage requirements are read at generate time. That
is exactly the shape of "the platform decides later".

Two alternatives further out were also rejected:

- **A superbuild (`ExternalProject_Add`) with the core installed and then found.**
  Clean isolation, and wrong for this tree: modules link `game` **statically**, need
  its include directories and its compile definitions, and the whole thing resolves on
  one link line. `ExternalProject` gives no target-level integration at configure
  time, so every one of those would have to be reconstructed by hand.
- **Leaving the core top-level and having it optionally `add_subdirectory(modules)`
  if the directory exists.** This is the status quo with a guard on it. It still
  requires the core to know that `modules/` is a thing, which is precisely the
  property the acceptance test forbids.

### What this cost the core, honestly

The core's root now exports twelve variables to `PARENT_SCOPE`: three install
directories, `DEP_ARCH`, the two output directories, the compile definitions and the
compiler flags. That is not decoration. Directory properties are inherited by
*children*, and `modules/` is a sibling — so without re-applying them at the platform
root, every module translation unit would compile core headers without `DO_MYSQL`,
without `SYSCONFDIR`, and without `DT_VIRTUAL_QUERYFILTER`. The last of those changes
whether `dtQueryFilter::getCost` is virtual. It links cleanly and produces pathfinding
that silently ignores every filter a module installs.
