# ADR-0026: Record the project's upstream lineage

- Status: Proposed
- Date: 2026-08-31
- Primary: WS-80 / WS-50

## Context

The project's ancestry was not written down anywhere in the repository. Reconstructing
it required reading GitHub: the root `README.md` names a fork parent, `docs/PROVENANCE.md`
names a filtered source commit, and `ops/windows/build/compile-tortoise-wow.ps1` clones a
third URL. None of them states the full chain, and no tag or `upstream` remote exists
locally to anchor it.

This matters beyond tidiness. Without a recorded lineage nobody can tell which upstream
a fix should be offered to, which project a bug report belongs in, or what licence and
attribution obligations apply. FG-005 already warns that confusing `origin` and
`upstream` can publish private work or reintroduce excluded content.

## Decision

Record the lineage as follows, and keep it current whenever the upstream of record
changes.

```
mangos-zero / VMaNGOS  (plus ports from AzerothCore)
  └── Penqle/tortoise-wow
        Turtle 1.18.1 restoration; contributed the modules/ script system and
        src/game/ScriptObjects.h
        └── r-o-sh, branch playerbots-integration-gh
              vendors ike3's cmangos playerbots under src/modules/PlayerBots/
              └── Shyalya/tortoise-wow @ playerbots-integration-gh
                    the upstream of record
                    └── Cilverkrow/twow-repo (this repository)
                          history filtered with git-filter-repo to strip binaries
```

Additional facts of record:

- Upstream remote of record: `https://github.com/Shyalya/tortoise-wow.git`, branch
  `playerbots-integration-gh` (`docs/PROVENANCE.md`).
- Source commit before filtering: `42b8a7f742548793910fe8880463aeeb71627fb9`; filtered
  equivalent `5a157e183e47cc5f892ef64ca69f02772118c940`. 559 rewritten commits are
  mapped in `docs/history/source-commit-map.tsv`.
- Effective upstream merge-base for the Penqle line:
  `db5fb2a197f05611ad9d243568122c6be466ab8a`, reachable only as `14d4cdc^2`. Nothing in
  the repository names it, which is why this ADR does.
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
- `UPSTREAM.lock` (ADR-0020) becomes the machine-readable form of the merge-base line
  recorded here; this ADR is the human-readable one.
- The missing ike3 vendor hash is now a recorded gap. Re-vendoring a newer playerbots
  release would be a large three-way merge whose exact ike3-relative size is unknown,
  and it needs a verified source baseline first.
- When the upstream of record changes, this ADR is superseded rather than edited, so
  the history of who we tracked stays legible.

## Evidence

- `docs/PROVENANCE.md`, `docs/history/source-commit-map.tsv`
- `README.md`, `AUTHORS.md`, `LICENSE`
- `ops/windows/build/compile-tortoise-wow.ps1`
- `src/modules/PlayerBots/README.md`, commit `1af237d`
