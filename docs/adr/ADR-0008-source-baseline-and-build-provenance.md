# ADR-0008: Baselines require clean source and build provenance

- Status: Accepted; amended 2026-09-02 (baseline anchor corrected)
- Date: 2026-08-30
- Primary: WS-10 / WS-50

## Context

The production executable embeds a shortened Git revision, but the live source tree contains pre-existing local changes and build artifacts. A revision string alone cannot prove the exact inputs used for a binary.

## Decision

Treat the recorded source anchor as the preferred upstream source line for the captured project state, not as proof that every production binary was built from a clean checkout.

**Amended 2026-09-02.** This ADR named `42b8a7f742548793910fe8880463aeeb71627fb9` as that anchor. It is not one: it identifies the *working tree the initial import was taken from*, and its filtered counterpart is a `twow-repo`-local identity that exists nowhere upstream. **The anchor is the fork point**, which [ADR-0026](ADR-0026-project-lineage-and-provenance.md) names and evidences -- the one place in the project that states it. `42b8a7f7`/`5a157e18` remain valid as the *import* record in `docs/PROVENANCE.md`; they are not a baseline anchor and must not be quoted as an upstream commit (FG-076).

A stable build baseline requires:

- full 40-character commit and tree identity;
- clean or completely classified `git status`;
- exact source/config/migration pins;
- compiler, SDK, dependency, generator, and CMake options;
- executable/PDB identity where relevant;
- build logs and a manifest;
- runtime compatibility evidence and a rollback artifact.

Dirty live-tree changes are preserved, hashed, and imported separately; they are never silently folded into a baseline. Builds should use an isolated worktree or checkout. A successful candidate build does not authorize installation.

## Consequences

- Short embedded hashes are supporting evidence only.
- Source, build, deployment, and runtime acceptance remain separate gates.
- Reproduced candidates retain exact manifests even when byte-identical reproduction is impossible.

## Evidence

- `runbooks/ssc-source-baseline-01-20260829-193848/stable-source-baseline-report.md`
- `runbooks/ssc-source-baseline-02c-r1-20260830-004551/REPORT.md`
- `docs/PROVENANCE.md`, `docs/adr/ADR-0026-project-lineage-and-provenance.md`
