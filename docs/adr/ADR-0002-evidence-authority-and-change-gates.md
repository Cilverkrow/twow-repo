# ADR-0002: Evidence authority and explicit change gates

- Status: Accepted
- Date: 2026-08-30
- Primary: WS-00

## Context

The project combines mutable runtime state, a dirty live source tree, compacted chats, database evidence, and immutable runbooks. Treating all statements as equally authoritative creates unsafe repairs and stale conclusions.

## Decision

Use this precedence when sources conflict:

1. current runtime and database evidence captured under an authorized scope;
2. current filesystem, Git, byte-count, and hash evidence;
3. the canonical workstream registry and global hub;
4. the owning workstream README;
5. verified reports, handoffs, and manifests;
6. other documentation;
7. chat recollection or summaries.

Facts, assumptions, proposals, and user decisions must be labeled separately. A contradiction is documented and blocks the affected action; it is not silently reconciled.

Diagnosis is read-only by default. Production database mutation, migration, deployment, process start/stop, rollback, active configuration change, and candidate installation each require explicit authorization. A completed analysis or build does not authorize the next phase.

Secrets are never copied to chat, evidence, scripts, or Git. Existing local changes are preserved and excluded from unrelated work.

## Consequences

- Every mutating task begins with exact targets, permissions, and preflight pins.
- `PASS` in one phase is not transitive authorization for deployment.
- Hash or identity drift causes `BLOCKED` unless the task explicitly authorizes reconciliation.
- Runbook manifests cover payloads but do not self-reference.

## Evidence

- `AGENTS.md`
- `runbooks/workstreams/README.md`
- `runbooks/project-collab-hub-source-metadata-correction-20260830T190536Z/`
- `runbooks/project-collab-hub-local-enforcement-20260830T175518Z/`
