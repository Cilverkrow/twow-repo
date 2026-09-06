# Playable Docker golden-state record

Date: 2026-09-06
Workstream: WS-60 (Reference server and backups)
Restore parity: PASS

## Local-only locator

The database dump remains outside Git.

- Storage class: `LOCAL_Y`
- Relative path:
  `golden-states\ws60-rndbot-50-playable-golden-state-20260906T171420Z\twow-golden-state.sql.gz`
- Bytes: `55039795`
- SHA-256:
  `F345B5570D942A9BE142F13AA1CAB70553D289E19B363AF1EAB6DA88CD3A374C`
- Isolated restore parity: `PASS`
- Secondary copy: `PENDING`

The relative locator is intentionally not converted into a repository path.
The dump is not a Git payload and must not be copied into this worktree.

## No-rebuild continuity contract

This contract reuses the retained image and volumes. It does not authorize or
require a rebuild.

### Preconditions

1. Verify that the retained image resolves to the exact digest recorded in the
   linked WS-50 attestation.
2. Verify the intended task-local database and runtime volumes by their retained
   identities; never select a volume by a broad name or wildcard.
3. Supply the existing task-local protected configuration and Compose overlay
   from their approved external location.
4. Keep extracted client data external and read-only.
5. Confirm that the task-local ports do not conflict with another server.

The protected configuration and exact operator invocation are intentionally not
tracked. Therefore this record specifies the required state transitions and
checks, but does not invent a copy-and-paste Compose command that could select
the wrong project, volumes, ports, or credentials.

### Restart

1. Resolve the protected overlay against the retained image digest and named
   volumes without running a build or fresh database bootstrap.
2. Start the database and require its health check to pass.
3. Start authentication and world services against that same database state.
4. Require both task-local listeners, zero unexpected restarts, roster version
   `1`, exactly 50 desired/active/online roster bots after readiness, and zero
   non-roster bots before declaring recovery.
5. Do not enable BotBrain or the LLM bridge as part of recovery.

### Stop

1. Require the human session to be logged out.
2. Send `saveall` through the supported world-console path and wait for its
   acknowledgement.
3. Request graceful world shutdown and verify exit code 0, no OOM condition,
   and durable online flags cleared.
4. Stop authentication gracefully. Keep the database running only while a
   separately authorized checkpoint or backup operation needs it; otherwise
   stop it through the same bounded task-local Compose project.
5. Never substitute a forced kill, broad Compose project selection, or prune.

### Restore

1. Verify the compressed dump's byte count and SHA-256 before use.
2. Restore only into a new, explicitly named, isolated database volume. Never
   overwrite the active candidate volume or the golden dump.
3. Inject database credentials through the approved protected mechanism; never
   place them in command lines, logs, this record, or Git.
4. Verify schema and migration-ledger compatibility, roster version/member set,
   ordered-set hash, canonical snapshot hash, GUID inclusion/exclusion, and
   zero online flags before starting services.
5. Start the restored copy only on isolated task-local ports and repeat the
   readiness checks above. Retain or remove the disposable restore volume only
   under a separate explicit authorization.

## Linked runtime proof

See the [WS-50 playable-candidate attestation](../../WS-50-build-serverbetrieb/ws50-rndbot-50-playable-golden-attestation-20260906/ATTESTATION.md).

The task-local raw server-log volume is not part of this golden state because it
may contain a disposable credential in an account-create command. Credential
rotation and log sanitization are prerequisites to any separate log archival.
