# ADR-0005: Preserve upstream history and modularize incrementally

- Status: **Superseded** on 2026-09-02 by ADR-0020 (two-repo split), ADR-0021 (module
  boundaries), ADR-0025 (repository structure) and ADR-0026 (lineage)
- Date: 2026-08-31
- Primary: WS-10 / WS-40

## Context

The project needs separation from its upstream source, but deep refactoring before the first import would collide with active work and make provenance harder to reconstruct.

## Decision

Preserve the upstream commit topology, authorship, dates, messages, and text changes in the independent repository. Rewrite only the independent copy to remove binary blobs from reachable history. Import uncommitted project source changes, operations files, runbooks, and documentation as later, ownership-visible commits.

Deep modularization is not a prerequisite for the initial import:

- keep the upstream-compatible source layout;
- keep PlayerBot/LLM code in the second module system it arrived in until interfaces
  stabilize;
- separate project-owned helper scripts at the repository boundary now;
- later extract a narrow LLM transport interface, versioned personality data, shared PowerShell lifecycle functions, and a manifest-driven deployment pipeline;
- perform each extraction as a separately reviewed and tested change.

## Consequences

- Upstream comparison and blame remain useful.
- The live tree is not refactored underneath active agents.
- Temporary structural debt is explicit and tracked by the modularization roadmap.
- Future module moves require build, dry-run, rollback, and deployment evidence.

## Evidence

- `docs/PROVENANCE.md`
- `docs/MODULARIZATION-ROADMAP.md`
- `ops/history/source-commit-map.tsv`

## Superseded 2026-09-02

Both halves of this decision are gone.

**"Keep one tree" was superseded by ADR-0020** and the split is executed: the platform
is `twow-repo`, upstream-shaped code is `twow-core`.

**The second module system it defers to no longer exists.** `src/modules/` is gone; the
vendored bot tree is `modules/mod-playerbots` and every feature is a module under
`modules/` (ADR-0021, ADR-0025). There is nothing left to "modularize incrementally"
along the line this ADR describes.

**Its stated consequence "upstream comparison and blame remain useful" is false.** This
repository's history was rewritten by `git-filter-repo` at creation, so it shares **no
ancestry with upstream**: `git merge-base` returns nothing, `git blame` cannot be
followed across the boundary, and no diff against an upstream commit is a diff against a
common ancestor. Upstream comparison is useful in `twow-core`, which is a genuine fork,
and only there. See [ADR-0026](ADR-0026-project-lineage-and-provenance.md) for the
lineage and the merge rules that follow from it.

What survives, and is carried by the ADRs above: the *binary-stripping* rewrite itself
(FG-006 still forbids a second one), the rule that each extraction is a separately
reviewed and tested change, and the ownership-visible import commits.
