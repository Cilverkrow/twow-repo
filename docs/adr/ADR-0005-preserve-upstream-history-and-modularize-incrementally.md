# ADR-0005: Preserve upstream history and modularize incrementally

- Status: Accepted
- Date: 2026-08-31
- Primary: WS-10 / WS-40

## Context

The project needs separation from its upstream source, but deep refactoring before the first import would collide with active work and make provenance harder to reconstruct.

## Decision

Preserve the upstream commit topology, authorship, dates, messages, and text changes in the independent repository. Rewrite only the independent copy to remove binary blobs from reachable history. Import uncommitted project source changes, operations files, runbooks, and documentation as later, ownership-visible commits.

Deep modularization is not a prerequisite for the initial import:

- keep the upstream-compatible source layout;
- keep PlayerBot/LLM code under `src/modules/PlayerBots` until interfaces stabilize;
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
- `docs/history/source-commit-map.tsv`
