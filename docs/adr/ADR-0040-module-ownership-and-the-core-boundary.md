# ADR-0040: Module ownership, and what the core is allowed to contain

- Status: Accepted
- Date: 2026-09-05
- Primary: WS-00 / WS-10
- Amends: the `TW_MODULES_DIR` design note in `core/CMakeLists.txt:53-58`

## Context

`twow-core` is a fork. `UPSTREAM.lock` records what of: `Shyalya/tortoise-wow`, branch
`playerbots-integration-gh`, fork point `61a8269`. We merge upstream into it, and the cost of doing
that is proportional to our delta. `twow-repo` consumes core as the `core/` submodule and has no
shared ancestry with it (its history was rewritten with git-filter-repo).

The stated goal is that core stays close to upstream so upstream can be merged regularly. Measured
against the fork point, at the pinned submodule commit `e3ab7b0` that the platform actually builds,
it is not close:

| area | files changed |
|---|---|
| `modules/` (mod-playerbots 1024, mod-dungeon-clear 591) | 1617 |
| `src/` (the engine) | 182 |
| `sql/` | 54 |
| everything else (dep, tools, cmake, CI, docs, dotfiles) | 35 |
| **total** | **1888** |

**86% of everything separating core from upstream is two modules, and neither module comes from
upstream.** At the fork point there are **zero** `ai_playerbot`/`mod-playerbots` files; upstream
ships only a small four-file `src/game/PlayerBots/`. The 280 "dungeon" paths upstream are
`src/scripts/dungeons/`, ordinary scripts, not `mod-dungeon-clear`. Both modules entered core
through our own commits — *"Move playerbots into the module system"* and *"Port
jrad7/mod-dungeon-clear onto the module system"*.

So core is not far from upstream because of engine work. The engine delta is 182 files. Core
is far from upstream because we put our product inside it.

Two consequences were already being paid, and are what prompted this ADR:

1. **Both modules exist twice**, once in core and once in the platform, and they have drifted in
   both directions. `mod-playerbots` is ~975 of 992 files byte-identical with the platform strictly
   ahead; `mod-dungeon-clear` has genuinely diverged both ways — core is ahead on eight route files
   and a Scarlet Monastery roster rework, the platform is ahead on error handling and test
   scaffolding.
2. **Neither copy in core is ever compiled.** Core's CI builds with `MODULES=disabled`, so those
   1617 files are duplication carrying no verification at all.

The duplication is not an accident. `core/CMakeLists.txt:53-58` makes module discovery exclusive —
*"There is deliberately no merging of the two - one directory wins, whole."* A platform that wants
its own modules must therefore vendor a copy of every module it also wants, including ours. The
build system forced the fork.

## Decision

**Core is the upstream engine plus the smallest delta that lets it serve us. Our modules are not
part of that delta.**

| | core | platform |
|---|---|---|
| upstream engine, and fixes to it | yes | no |
| build and portability (MSVC) | yes | no |
| the hook system modules attach to | yes | no |
| our modules — playerbots, dungeon-clear, bot-brain, donation, leech, solo-dungeon, worldbuff | no | yes |
| services, deployment, CI, docs, ADRs | no | yes |

A change belongs in core only if it is **upstream-shaped**: a fix to upstream code, a portability
fix, or an additive hook that lets our code attach without rewriting upstream logic. Anything else
in core is a smell, and the question to ask is "why can this not attach from outside?"

Our changes are tracked in the platform, normally, with no special ceremony. The exception is the
small set that genuinely must live in core; each of those is a topic branch on core, kept small and
upstream-shaped so it survives a rebase and can be reasoned about on its own.

### Why the modules move to the platform rather than the other way round

The platform cannot hold upstream code without forking it — it has no shared ancestry, so anything
of upstream's it held would be a copy that upstream merges could never reach. Upstream code
therefore has exactly one possible home, and that is core. Our code has a genuine choice, and the
tie is broken by merge cost: every file of ours in core is a file an upstream merge has to consider.

### What this does to `TW_MODULES_DIR`

Nothing, and that is the point. Its exclusivity was a problem only because both repositories wanted
modules. With core owning none, "one directory wins" is no longer a constraint anyone feels. The
design note at `core/CMakeLists.txt:53-58` is amended to say so rather than left to be discovered as
folklore.

### What this does not decide

Whether core should ship a *usable server* on its own. It still can: a server without our modules is
still a server, and core's CI already builds exactly that configuration today. Bots are a platform
feature, not an engine one.

## Consequences

- Core's delta drops from 1888 files to roughly 270. That is a delta a person can read, and rebase
  onto upstream without dreading it.
- The two copies collapse to one, so drift-in-two-directions stops being possible.
- **Three previously-planned "push down into core" branches evaporate.** The async-LLM fix, the
  `AddPlayerBot` session leak and `PersistentActiveRoster` were only worth porting because there
  were two copies. With one, they simply live where the module lives. This ADR deliberately records
  that the earlier recommendation was solving the wrong problem.
- The seam question is moot. `AiContextAugment` and `RegisterAiContextAugmenter` live *inside*
  `mod-playerbots`, with no occurrence anywhere under `core/src`. Moving the module takes the seam
  with it; core needs no seam of its own for `mod-bot-brain` to attach.
- `mod-dungeon-clear` must be reconciled **before** core's copy is deleted, and this is the one
  genuinely fiddly step. Core is ahead there. Deleting first would lose that work.
- What survives as core work is small and honest: the MSVC portability fix (`DC_MSVC_EXPAND` in
  core's `AcCompat.h:487`, which the platform lacks and correctly so — core supports Windows and the
  platform's Windows compile is deliberately gated off), plus real engine fixes.
- Core keeps `MODULES=disabled`, which it already does, so nothing about its CI changes.

## Sequence

1. This ADR.
2. Reconcile `mod-dungeon-clear` into the platform — a real merge, both directions.
3. Reconcile `mod-playerbots` into the platform — confirm nothing exists only in core.
4. Delete core's `modules/mod-playerbots` and `modules/mod-dungeon-clear`.
5. Re-pin the submodule; confirm the platform still builds.

Steps 2 and 3 must both complete before step 4. That ordering is the whole safety property.

## Evidence

- `UPSTREAM.lock` — upstream is `Shyalya/tortoise-wow` `playerbots-integration-gh` at `61a8269`.
- `git diff --name-only 61a8269 e3ab7b0` in core — 1888 files, 1617 of them under `modules/`.
- `git ls-tree -r 61a8269 | grep -c 'ai_playerbot\|mod-playerbots'` — **0**.
- `git log --diff-filter=A -- modules/mod-playerbots/mod-playerbots.cmake` — added by our own commit.
- `core/CMakeLists.txt:53-58` — the exclusivity note this ADR amends.
- `core/CMakeLists.txt:88` — `MODULES` defaults to `disabled`; core never compiles its own copies.
- `core/modules/mod-dungeon-clear/src/AcCompat.h:487` — `DC_MSVC_EXPAND`, present only in core.
- `core/modules/mod-playerbots/src/playerbot/PlayerbotMgr.cpp:228` — the acknowledged session leak.
- `docs/adr/ADR-0039-bot-brain-identity-and-memory.md` — the module whose attachment proves the seam
  needs nothing from the engine.
