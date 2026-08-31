# ADR-0006: Separate operations ownership and use graceful shutdown

- Status: Accepted
- Date: 2026-08-28
- Primary: WS-40 / WS-50

## Context

Builds, deployment automation, configuration, runtime observation, backups, and process control were previously mixed. Windows console titles and helper assumptions also caused partial shutdowns.

## Decision

Separate responsibilities:

- WS-30 owns sanitized configuration values and runtime parameters.
- WS-40 owns deployment and lifecycle automation.
- WS-50 owns builds, process state, logs, and reproducible runtime verification.
- WS-60 owns backup and restore material.

Shutdown order is Worldserver, Realmd, then MariaDB. Worldserver receives its supported save/shutdown commands. Realmd is accepted only after PID, full executable path, PID file, and one of the explicitly supported console titles agree, then receives `CTRL_BREAK_EVENT`. MariaDB uses its reviewed administrative shutdown path. Helpers fail closed on identity ambiguity.

Forced name-based termination such as `taskkill` is not the normal or fallback behavior. A helper may report a partial stop, but must not kill an unverified process.

## Consequences

- A title mismatch cannot silently stop the wrong console.
- Already-stopped components are treated deterministically.
- Deployment scripts reference backups and configs owned elsewhere instead of embedding them.
- Process operations remain separately authorized even when helper tests have passed.

## Evidence

- `runbooks/shutdown-helper-console-lab/`
- `runbooks/world-shutdown-smoke-evidence-20260828-160724-135/`
- `ops/windows/server/shutdown-tortoise-servers-gracefully.ps1`
