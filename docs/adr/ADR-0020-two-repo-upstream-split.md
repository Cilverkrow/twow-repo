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
`modules/mod-playerbots` to use Penqle's names moves the compatibility burden to where
the incompatibility actually is. That trades merge pain with upstream for merge pain with
the imported PlayerBots line.

The previously reported 255-path figure is a snapshot-specific, graft-relative count,
not an ike3 delta. It is reproducible at `ed32ae41` against the PlayerBots subtree in
graft checkpoint `0af2567767de69a819287acaab4c5c947cc1e04c`, which describes itself as
"cmangos/playerbots port grafted onto Penqle/tortoise-wow 1181dev" and is already a
port. The content-equivalent checkpoint in this repository's rewritten history is
`1af237d5346456dd6a5d457b0759be3215790f4c`; both commits resolve the PlayerBots
subtree to `9bd691ccdccf88ebdbe362d293337068ec01a636`.

The count is not current even on the old path: at tested roster baseline `3c2b931`, the
same raw tree comparison reports 267 changed paths. The later module promotion changes
the path layout, so post-promotion counts require an explicit mapping and must not be
compared as if they used the same namespace. Neither repository records a verified ike3
remote, tag or source commit for the import. The true delta from upstream ike3 is
therefore unknown; establishing that baseline is separate provenance work, not a
prerequisite for this split.

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
- `docs/history/source-commit-map.tsv` maps `0af2567` to `1af237d`; both resolve
  `src/modules/PlayerBots` to tree `9bd691ccdccf88ebdbe362d293337068ec01a636`.
- Counting the output of
  `git diff --name-only 0af2567:src/modules/PlayerBots ed32ae41:src/modules/PlayerBots`
  gives 255 paths; substituting `3c2b931` for `ed32ae41` gives 267.
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
