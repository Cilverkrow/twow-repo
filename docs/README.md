# Project documentation map

This repository is a source-controlled project view, not a self-contained server installation. Start here before building, testing, or operating it.

## Current project state

- [Root TODOs](../TODOS.md) — concise checklist of every open work item; never execution authorization.
- [Open threads](OPEN-THREADS.md) — unfinished work, ownership, dependencies, and next gates.
- [Footguns](FOOTGUNS.md) — known ways to produce a wrong result, damage state, or misread the evidence.
- [External requirements](EXTERNAL-REQUIREMENTS.md) — tools, runtime data, services, credentials, and artifacts intentionally absent from Git.
- [Windows build resources](BUILD-RESOURCES.md) — pinned external icon/library prerequisites and their temporary materialization contract.
- [Compiler warning triage](COMPILER-WARNING-TRIAGE.md) — REF-005 classifications, repository ownership, and follow-up gates.
- [Claude Code restructuring handover](HANDOVER-CLAUDE-CODE.md) — verified starting state, constraints, intended module seams, and proposal criteria.

## Decisions and boundaries

- [Architecture Decision Records](adr/README.md)
- [Decision register](adr/DECISION-REGISTER.md)
- [Reconstruction sources](adr/SOURCES.md)
- [Repository boundaries](REPOSITORY-BOUNDARIES.md)
- [Repository provenance](PROVENANCE.md)
- [Modularization roadmap](MODULARIZATION-ROADMAP.md)
- [Security policy](SECURITY.md)

## Authority warning

The repository documents and reproduces work, but it does not authorize deployment, database mutation, process control, or rollback. Current verified runtime state outranks these documents. Historical runbooks can contain workstation-specific absolute paths and point-in-time observations; treat them as evidence, not executable instructions.

The long-form root `README.md` is inherited from the source fork and contains historical feature descriptions. Its claims about bot counts, enabled features, and runtime behavior are not a current operations status page. Use the files above, the collaboration hub under `runbooks/workstreams`, and fresh runtime evidence instead.
