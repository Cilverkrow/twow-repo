# ADR-0026: Record the project's upstream lineage

- Status: Accepted
- Date: 2026-09-02 (replaces the 2026-08-31 draft's lineage block)
- Primary: WS-80 / WS-50

> **This ADR is the single authority for the project's lineage.** The fork point, the
> upstream of record, the repositories in the chain and the merge rules are stated here
> and **nowhere else**. Every other document links here instead of restating them. Five
> documents once stated the lineage independently, two of them disagreed, and an agent
> that trusted the wrong one test-merged a dead branch and measured a whole delta
> against a stale ref. That is why this rule exists.

## Context

The project's ancestry was not written down anywhere in the repository. Reconstructing
it required reading GitHub: the root `README.md` named a fork parent, `docs/PROVENANCE.md`
named a filtered source commit, and `ops/windows/build/compile-tortoise-wow.ps1` clones a
third URL. None of them stated the full chain, and no tag or `upstream` remote existed
locally to anchor it.

The first version of this ADR then got three things wrong itself: it named a phantom
intermediate account in the chain, it cited a **local** post-`git-filter-repo` hash as
the "effective upstream merge-base", and it omitted `Cilverkrow/twow-core` entirely. The
block below replaces it and was verified against the GitHub API and against `git` on
2026-09-02.

This matters beyond tidiness. Without a recorded lineage nobody can tell which upstream
a fix should be offered to, which project a bug report belongs in, what may be merged
where, or what licence and attribution obligations apply.

## Decision

### The chain

```
mangos-zero / VMaNGOS  (plus ports from AzerothCore)
  |
  v
Penqle/tortoise-wow          the real Turtle-WoW. 303 stars. NOT a fork.
  |                          Turtle 1.18.1 restoration; contributed the modules/
  |                          script system and src/game/ScriptObjects.h.
  v
Shyalya/tortoise-wow         a public fork by GitHub user Shyalya, an UNRELATED
  |                          THIRD PARTY (account created 2025-04-05). Fork created
  |                          2026-07-28. Live branch: playerbots-integration-gh
  |                          (their default HEAD). Commits daily.
  |                          THE UPSTREAM OF RECORD.
  v
Cilverkrow/twow-repo         this repository. Its history was rewritten by
  |                          git-filter-repo at creation, so it shares NO ancestry
  |                          with upstream: `git merge-base` returns nothing, and it
  |                          can NEVER `git merge` from upstream, at any path.
  v
Cilverkrow/twow-core         branched from the REAL fork point 61a8269. Shares
                             history with upstream. THE ONLY PLACE UPSTREAM MERGES
                             CAN HAPPEN.
```

There is no intermediate account between Penqle and Shyalya. Penqle forks directly to
Shyalya; a chain naming a third account between them is unsupported and was removed from
this ADR on 2026-09-02.

### The fork point

**The fork point is `61a8269`** -- "Merge pull request #404 from Penqle/1181dev", in
`Shyalya/tortoise-wow`. `twow-core` is branched from it. This is the only *statement* of
the fork point in the repository; nothing else may restate it. The one other place the
hash appears is `UPSTREAM.lock`'s `UPSTREAM_BASE`, which is this ADR's machine-readable
projection for the nightly drift job (see Consequences) and carries no argument of its
own.

The mapping to this repository's rewritten history is confirmed **by content, not by
hash**: every file under `src/game` is byte-identical between `61a8269` and the
corresponding filtered commit here. The only difference is the 146 warden `.cr`/`.key`
binaries that `git-filter-repo` stripped -- which `twow-core`, as a genuine fork, gets
back. The original-to-filtered mapping for all 559 rewritten commits is machine-recorded
in `ops/history/source-commit-map.tsv`; that file is generated evidence, and it lives
outside `docs/` on purpose. Its second column is a `twow-repo`-local identity for every
row, the fork point's included, and the last time such an identity was read out of a
lookup and written into a document it was quoted as "the upstream merge-base" and cost a
day (FG-076). **No document states a filtered-side identity for the fork point.** The
upstream identity above is the only one this project uses, and `61a8269` is resolvable
where it matters: `git -C core cat-file -e 61a8269...` succeeds, and it is an ancestor of
`core`'s tip.

### Merge rules that follow

- **`twow-repo` never merges from upstream.** Not `git merge`, not `git pull`, not
  `git subtree`, not "just this one path". There is no common ancestor to merge against.
  Anything presented as an upstream merge into this repository is a mistake (FG-007).
- **`twow-core` is the only place upstream merges happen**, and there they are ordinary.
- **The only correct upstream ref to measure against is
  `upstream/playerbots-integration-gh`.** Upstream's `main`, `dev`, `1181dev`,
  `challenges`, `shop` and `1181-rogue-fixes` branches are all **ancestors of the fork
  point** -- dead. Measuring, diffing or test-merging against them produces nonsense.
- **A hash that resolves locally is not an upstream hash.** Every commit identity in
  this repository was rewritten at creation, so it exists nowhere upstream. Before
  asserting any hash as upstream, resolve it on the upstream remote (FG-076).

### Shyalya is a stranger, not a collaborator

Shyalya is an unrelated third party: not a co-developer, not a second team working on
one shared project, and their branch is not a co-developed sibling of ours. Their
commits carry a `Co-Authored-By: Claude` trailer only because they also use Claude; that
was once
misread as evidence of shared work. Nothing follows from that about direction: we merge
FROM Shyalya into `twow-core` and carry our delta there permanently. We do not send
changes to Penqle or to Shyalya.

Two consequences of record:

- **`modules/mod-dungeon-clear` in this repository is shyalya's work**, not ours --
  commits `1792e0cf`, `f65898ec`, `0638fe21` (2026-08-22 / 2026-08-24). It must be
  credited to them wherever the project lists what it added.
- **Upstream is 385 commits ahead of the fork point** and independently built much of
  what this project built. `8415f1b` (2026-09-01) moved playerbots to
  `modules/mod-playerbots` -- the same layout this project arrived at. Upstream's core
  **contains** `modules/`, and upstream holds the script-hook seam
  (`src/game/ScriptObjects.h`, `src/game/ModuleSlots.h`, `src/game/PlayerbotStubs.cpp`)
  and has deleted its own `src/game/PlayerBots/`. Upstream has also already fixed bugs
  this project fixed: `c388a7e` (the snare freeze, the same `ratio=10` diagnosis),
  `be0706b` (the `m_visibleGUIDs` lock) and `9baa692` (crash families).

### Paths

The vendored ike3 bot tree lived under `src/modules/` until the promotion; it is
`modules/mod-playerbots` today, and `src/modules/` no longer exists. Historical commands
and diffs that reference the pre-promotion path are valid only at pre-promotion commits
and must say so.

### Other facts of record

- Upstream remote of record: `https://github.com/Shyalya/tortoise-wow.git`, branch
  `playerbots-integration-gh`.
- The initial import's source commit before filtering was
  `42b8a7f742548793910fe8880463aeeb71627fb9`, filtered to
  `5a157e183e47cc5f892ef64ca69f02772118c940`. **These identify the import, not the fork
  point** -- `5a157e18` is a local identity, and `42b8a7f7` records the working tree the
  import was taken from, not the branch anchor. `61a8269` is the anchor.
- The playerbot vendor point is commit `1af237d`, which cherry-picks
  `323283ffae0e08a92af99c11faf642386538ebd8` from a repository not reachable here and
  references a tag `bot-port-fullfat` that does not exist locally. **No upstream ike3
  commit hash is recorded anywhere.** This is an open provenance gap, not a fact.
- Related downstream projects that build this same fork and are useful prior art:
  `kasperfriend/tortoise-oneclick-compiler` (the ancestor of
  `ops/windows/build/compile-tortoise-wow.ps1`) and
  `Nescabir/tortoise-docker` / `kasperfriend/tortoise-docker`, which already publish
  container images of it.
- Licence: AGPL-3.0, inherited. Modules that link the core are derivative works and
  carry the same licence.

## Consequences

- A fix can be routed to the right upstream without archaeology.
- The class of error that cost a day -- trusting a local hash as an upstream one, or
  measuring against a dead branch -- is now checkable against one document rather than
  five.
- `UPSTREAM.lock` (ADR-0020) becomes the machine-readable form of the fork point
  recorded here; this ADR is the human-readable one. If they disagree, this ADR is stale
  or the lock is; resolve against the upstream remote, not against either file.
- Upstream having independently reached `modules/mod-playerbots` removes the path
  collision that REF-016 and PROV-02 were opened for.
- The missing ike3 vendor hash remains a recorded gap. Re-vendoring a newer playerbots
  release would be a large three-way merge whose exact ike3-relative size is unknown,
  and it needs a verified source baseline first.
- When the upstream of record changes, this ADR is superseded rather than edited, so
  the history of who we tracked stays legible.

## Evidence

- GitHub API, 2026-09-02: `Penqle/tortoise-wow` (`fork: false`, 303 stars);
  `Shyalya/tortoise-wow` (`fork: true`, parent `Penqle/tortoise-wow`, created
  2026-07-28, default branch `playerbots-integration-gh`); user `Shyalya` created
  2025-04-05.
- `git merge-base origin/main shyalya/playerbots-integration-gh` returns nothing.
- `ops/history/source-commit-map.tsv` (generated by `git-filter-repo`)
- `docs/PROVENANCE.md`, `README.md`, `AUTHORS.md`, `LICENSE`
- `ops/windows/build/compile-tortoise-wow.ps1`
- `modules/mod-playerbots/README.md`, commit `1af237d`
