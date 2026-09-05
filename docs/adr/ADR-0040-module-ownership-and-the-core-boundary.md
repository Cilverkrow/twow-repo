# ADR-0040: Module ownership, and what the core is allowed to contain

- Status: Accepted
- Date: 2026-09-05
- Primary: WS-00 / WS-10
- Supersedes: an earlier draft of this same ADR, whose central measurement was wrong. The error
  and its cause are recorded below rather than deleted, because the mistake is instructive and
  someone will otherwise make it again.

## Context

`twow-core` is a fork. `UPSTREAM.lock` records what of: `Shyalya/tortoise-wow`, branch
`playerbots-integration-gh`, fork point `61a8269`. We merge upstream into it, and the cost of doing
that is proportional to our delta. `twow-repo` consumes core as the `core/` submodule and has no
shared ancestry with it (its history was rewritten with git-filter-repo).

Both repositories contain `mod-playerbots` and `mod-dungeon-clear`. The copies had drifted in both
directions, neither copy in core was ever compiled by core's CI (`MODULES` defaults to `disabled`),
and work was happening in both places. The question is which repository owns them.

### The measurement that answers it, and the one that misled me

Measured against the **fork point**, core's delta looked like this: 1888 files, of which 1617 were
those two modules. At the fork point there are **zero** `mod-playerbots` and **zero**
`mod-dungeon-clear` files. The obvious reading — the one this ADR originally took — is that 86% of
what separates core from upstream is our own product, and that moving it out would collapse the
delta to something rebaseable.

That reading is **wrong**, and the reason is that a fork point is not the upstream. Upstream
*adopted both modules after we forked*. They arrive in core through merges, not through our
commits. Measured against the upstream tip instead, after the catch-up to `6be01e53`:

| area | files differing from upstream |
|---|---|
| `modules/mod-playerbots` | **2** of 1024 |
| `modules/mod-dungeon-clear` | **1** of 647 |
| `src/` (the engine) | **44** |

Core's real delta from upstream is about **47 files**, not 1888. Those modules are essentially
upstream's, verbatim. The 1617 files were never our product; they were upstream's work that we had
merged, and diffing against a point in history before upstream wrote it made them look like ours.

Upstream is also the *active* developer of one of them. Of the 115 files changed in the last 75
upstream commits, **82 are `mod-dungeon-clear`** — Maraudon routes, Zul'Farrak recordings, roster
directives, follower geometry. That is not a dormant vendored dependency; it is the part of
upstream moving fastest.

## Decision

**Upstream-tracked code lives in core. Only code we actually wrote lives in the platform.**

| | core | platform |
|---|---|---|
| the engine, and our fixes to it | yes | no |
| `mod-playerbots`, `mod-dungeon-clear` | **yes** | no |
| our own modules — `mod-bot-brain`, `mod-donation`, `mod-leech`, `mod-solo-dungeon`, `mod-worldbuff` | no | yes |
| services, deployment, CI, docs, ADRs | no | yes |

The test is provenance, not convenience: **if a merge from upstream can deliver a change to this
file, the file belongs in core.** Keeping such a file in the platform does not reduce merge cost, it
converts an automatic merge into a manual port, forever. Deleting `mod-dungeon-clear` from core
would have turned every future Maraudon route into a hand-carried patch.

Our changes to upstream-tracked modules therefore go **into core**, as small topic branches, each
kept upstream-shaped so it survives a rebase. That is the opposite direction from this ADR's first
draft, and it is the direction that keeps merges cheap.

### The build-system change this requires

`core/CMakeLists.txt` made module discovery exclusive — *"There is deliberately no merging of the
two - one directory wins, whole."* That is what forced the fork in the first place: a platform that
wants its own modules had to vendor a copy of every module it also wanted, including upstream's.

`TW_MODULES_DIR` becomes a **list** of module roots, searched in order. Core keeps its own; the
platform sets `core/modules;modules` and adds its own alongside without copying anything. This is
the enabling change, and without it the split above cannot be expressed at all.

### What the platform gives back

The platform's forks carry real work that must land in core before those forks are deleted:

- `PersistentActiveRoster` and `PersistentActiveRosterDatabase` — the CAS-versioned, fail-closed
  roster that is the remediation for bots being lost across a restart. Core has none of it.
- The async LLM debug path. Core's `PlayerbotLLMInterface::Generate` is a blocking HTTP call made
  from the chat-command handler, i.e. on the world update thread; an unreachable endpoint stalls
  the server. (Both copies gate on `SEC_MODERATOR`, so this is not a hole any player can reach.)
- `AddPlayerBot` returning `bool` and cleaning up on the login-failure path. Core leaks
  `botSession` there and says so: *"botSession leaks here … Acceptable for smoke testing; fix if
  needed."*
- The recorded-route collector fix. `RecordedRoutes.cpp` calls 7 register functions while 97
  translation units define one, so 90 routes are dropped by the linker and do not exist at
  runtime. Byte-identical in both trees, so it is core's bug too.

The `cv_bots` schema split stays platform-side: it presumes a database topology core knows nothing
about.

## Consequences

- Core keeps 1617 files it would have deleted, and that is correct: they are upstream's, and the
  merge channel that delivers them stays open.
- The platform stops carrying forks of upstream modules. One copy of each, in core.
- Our module work becomes core PRs. That is more ceremony per change and it is the right trade:
  the alternative is re-porting upstream's dungeon-clear work by hand every catch-up.
- `TW_MODULES_DIR` must become a list before any of this can land. It is the load-bearing
  prerequisite, not a detail.
- **Three earlier decisions in this workstream were wrong and are reversed here.** The
  reconciliation that copied core's `mod-dungeon-clear` into the platform (twow-repo #188) moves
  work the wrong way. The deletion of both modules from core (twow-core #37) would close the merge
  channel. And this ADR's own first draft argued for both. Recording that is cheaper than letting
  someone rediscover it.
- The seam is unaffected either way: `AiContextAugment` and `RegisterAiContextAugmenter` live
  inside `mod-playerbots`, with no occurrence anywhere under `core/src`.

## The lesson worth keeping

**A fork point is not the upstream.** Diffing against the commit you forked at measures everything
that has happened since — on both sides — and silently attributes all of it to you. When the
question is "how much of this is ours", the only honest baseline is the upstream tip, fetched.
Every number in the first draft of this ADR was arithmetically correct and pointed at the wrong
conclusion.

## Evidence

- `git diff --name-only chore/upstream-catchup-6 shyalya/playerbots-integration-gh` — 2 files in
  `mod-playerbots`, 1 in `mod-dungeon-clear`, 44 in `src/`.
- `git ls-tree -r 61a8269 -- modules/mod-playerbots` — 0 files at the fork point; 1024 at the
  upstream tip today.
- `git log 3a978d77..shyalya/playerbots-integration-gh` — 75 commits, 82 of 115 changed files in
  `mod-dungeon-clear`.
- `core/CMakeLists.txt` — the exclusivity note this ADR requires changing.
- `core/CMakeLists.txt:88` — `MODULES` defaults to `disabled`; core never compiles its own copies.
- `core/modules/mod-playerbots/src/playerbot/PlayerbotMgr.cpp` — the acknowledged session leak.
- `modules/mod-dungeon-clear/src/Routes/RecordedRoutes.cpp` — 7 collected, 97 defined.
