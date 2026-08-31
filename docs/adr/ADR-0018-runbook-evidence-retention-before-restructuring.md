# ADR-0018: Keep sanitized runbook evidence in the main repository for now

- Status: Accepted
- Date: 2026-08-31
- Primary: WS-00 / WS-80

## Context

Project tasks repeatedly require “separate evidence.” This describes immutable, task-specific evidence directories, not a requirement for a separate Git repository. A repository split immediately before the planned architectural refactoring would add link migration, synchronization, access, and provenance work while the source and deployment boundaries are still changing.

The refactoring handover must nevertheless include the decisions, open work, and evidence needed by a new tool or agent. Raw build output, binaries, symbols, archives, production logs, database dumps, credentials, and licensed game data remain unsuitable for Git.

## Decision

For the current repository and upcoming restructuring:

- keep relevant sanitized text-only runbooks under `runbooks/` in the main project repository;
- keep each task/revision in its own immutable directory and create a new directory for later corrections;
- import only allowlisted text, scripts, hashes, matrices, reports, and handoffs after secret, binary, and size review;
- represent excluded payloads through identity, size, hash, and external retention information rather than copying them into Git;
- keep `TODOS.md` and `docs/OPEN-THREADS.md` as indexes, not execution authorization;
- preserve historical chat content in its original chats and carry only verified decisions, open questions, and cross-references into the repository;
- defer any separate evidence/runbook repository until after the restructuring has stable identifiers and link, retention, access, and synchronization contracts.

## Consequences

- Claude Code and later agents receive the necessary project history in one clone without receiving private runtime payloads.
- Runbook history can grow, so imports require explicit relevance and content-boundary review.
- The main repository is not a complete backup of evidence excluded for size, licensing, privacy, or security.
- A later split is possible but must preserve immutable identities and repository-relative references through a planned migration.

## Evidence

- `docs/REPOSITORY-BOUNDARIES.md`
- `docs/HANDOVER-CLAUDE-CODE.md`
- `docs/OPEN-THREADS.md`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-provenance-aware-source-integration-20260831T192201Z/`
- `runbooks/workstreams/WS-10-ssc-analyse-entwicklung/ot-001-r1-provenance-aware-source-integration-recovery-20260831T220000Z/`
