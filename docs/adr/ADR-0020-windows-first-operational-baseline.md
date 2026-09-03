# ADR-0020: Windows-first operational baseline; containerization deferred

- Status: Accepted
- Date: 2026-09-03
- Primary: WS-80
- Dependent: WS-10 / WS-30 / WS-40 / WS-50

## Context

The project has a working local Windows server and the current operator is
testing its gameplay directly. Container and Linux bootstrap work is useful
future infrastructure work, but it introduces a second deployment model,
database-initialization path, service lifecycle, and evidence surface before
the current platform is fully proven.

The immediate product goal is a robust, playable Windows server with persistent
bot identity and a later optional, failure-isolated local LLM path. These goals
do not require Docker, Linux, Kubernetes, or a microservice split.

## Decision

Windows remains the sole active runtime and deployment target until a separate
architecture decision authorizes another platform. No containerization,
Linux-host migration, or production Docker database bootstrap is required for
the current delivery path.

The required Windows-first sequence is:

1. Prove and maintain reliable local Windows operation: controlled startup and
   shutdown, playable login, observable bot operation, and bounded repair of
   Windows/MariaDB issues when evidenced.
2. Deploy and verify the accepted persistent roster through its separately
   authorized Phase C gate: exactly 50 selected bots must persist across
   restarts and must not be silently replaced.
3. Prove controlled roster growth and reduction. Growth is append-only;
   reducing the active population deactivates existing roster members rather
   than deleting their characters, identities, progression, or future return
   path.
4. Only after stable roster identity, complete the separately gated, disabled
   by default Ollama/LLM bridge and bind it to approved bot-profile/personality
   data. The bridge remains narrow and fail-closed; a bridge or inference
   failure must not affect ordinary game or bot operation.

Existing container findings, including db-init migration safety work, are
retained as future-platform evidence. They do not authorize a change to the
Windows server and must not displace the Windows validation sequence.

The non-binding follow-on product ideas and discovery gates are recorded in
[`docs/BOT-PROGRESSION-SIDEQUESTS.md`](../BOT-PROGRESSION-SIDEQUESTS.md). That
backlog does not amend this decision or authorize implementation.

## Consequences

- Current effort stays focused on the server the operator can play and inspect
  today, avoiding parallel infrastructure complexity.
- ADR-0010 remains the authority for roster identity; this ADR sets its
  operational priority and requires deactivation rather than destructive
  reduction.
- ADR-0012 and ADR-0013 remain the authority for the LLM process and protocol;
  this ADR makes their live Windows admission a later prerequisite, not a
  container project.
- A later Linux/container proposal needs a fresh ADR and must include a
  Windows-baseline comparison, data-migration/rollback plan, service ownership,
  and independent bootstrap evidence. It is not an automatic next step.

## Evidence

- ADR-0010: Persistent ordered GUID roster with no automatic replacement.
- ADR-0012: External LLM child process with fail-closed admission.
- ADR-0013: LLM wire, package, and child-lifecycle contract.
- `TODOS.md` OT-002, OT-003, OT-004, OT-005, and OT-024.
