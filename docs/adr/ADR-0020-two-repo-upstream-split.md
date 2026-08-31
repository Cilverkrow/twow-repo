# ADR-0020: Split upstream and project code across two repositories

- Status: Proposed
- Date: 2026-08-31
- Primary: WS-00 / WS-10 / WS-50
- Supersedes: the "keep one tree" half of ADR-0005

## Context

Upstream code and project code are currently indistinguishable in one tree. Measured
against the upstream tip `db5fb2a`, 114 core files differ (+5,246 / −1,809), and the
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
