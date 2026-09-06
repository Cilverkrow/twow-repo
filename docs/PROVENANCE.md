# Repository provenance

> **Lineage lives in [ADR-0026](adr/ADR-0026-project-lineage-and-provenance.md), not
> here.** The chain of repositories, the fork point, the upstream of record and the merge
> rules are stated there and only there. This file records what the *initial import* did
> to this repository's history. It previously carried a partial copy of the lineage, and
> that copy is where a local post-filter hash first got quoted as an upstream merge-base
> -- an error that cost a day (FG-076).

The server source was copied from the independent working tree `C:\TW\ComTW\source` without changing that tree.

## What this repository can and cannot do with upstream

**`twow-repo` can never merge from upstream.** The import rewrote every commit with
`git-filter-repo`, so this repository shares **no ancestry** with
`Shyalya/tortoise-wow`: `git merge-base` returns nothing, and no merge, pull, subtree or
single-path merge from upstream is possible here. `Cilverkrow/twow-core`, branched from
the fork point, is the only place upstream merges happen. See ADR-0026.

It follows that **every commit hash in this repository is local-only**. None of them
resolves upstream. Before quoting a hash as upstream, resolve it on the upstream remote
(FG-076).

## Import record

These identify the **import**, not the fork point. The fork point is in ADR-0026.

- Upstream remote: `https://github.com/Shyalya/tortoise-wow.git`
- Source branch: `playerbots-integration-gh`
- Source commit before filtering: `42b8a7f742548793910fe8880463aeeb71627fb9`
- Filtered equivalent commit: `5a157e183e47cc5f892ef64ca69f02772118c940` (a local
  identity; it exists nowhere upstream)
- Preserved rewritten commit count: 559

The history was rewritten only in the independent repository copy so that binary files are absent from every reachable commit. The rewrite removes compiled libraries, executables, symbols, archives, images, Warden binary modules, client/server data files, and any other blob detected as binary. Commit topology, authorship, dates, messages, and text changes are otherwise retained.

`ops/history/source-commit-map.tsv` records the original-to-filtered commit mapping produced by `git-filter-repo`. It is generated evidence: it is the proof that a given local hash corresponds to a given upstream one, and it is the only place filtered-side hashes are written down. Do not hand-edit it, and do not read a filtered-side hash out of it and then quote it as upstream.

It sits under `ops/` rather than under `docs/` for exactly that last reason. This file is where a filtered-side identity was first copied out of that lookup and written up as an upstream merge-base, and two ADRs then quoted it from here (FG-076). Keeping the mapping out of the prose tree makes that copy impossible to make by accident: no document under `docs/` carries a filtered-side identity for the fork point. See `ops/history/README.md`.

Uncommitted PlayerBot/LLM changes from the live source tree are imported in a separate new commit after the cleaned baseline. Operations files and runbooks are likewise imported in later commits so their ownership remains visible.

## Third-party content in this repository

`core/modules/mod-dungeon-clear` was authored by shyalya (commits `1792e0cf`, `f65898ec`,
`0638fe21`, 2026-08-22 / 2026-08-24), not by this project. It arrived with the import.
See ADR-0026.
