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

### Platform amendment (2026-09-01)

The ownership, ordering, identity-validation, no-force-kill, and graceful-shutdown
rules remain accepted. The Windows `WriteConsoleInput` implementation does not.
The same helper bytes passed an earlier interactive evidence run, then failed in a
later headless production invocation at the first command write before `saveall` was
delivered. This proves that the earlier result was not a generally reliable operating
contract; it does not prove that every interactive invocation fails.

ADR-0028 makes Linux/Docker the supported deployment platform and Windows a compile-only
target. The supported implementation is therefore the container console FIFO in
`deploy/docker/entrypoint-mangosd.sh`, which translates termination into `saveall` and
`server shutdown 0`. The Windows helper is retained byte-for-byte as historical evidence,
is unsupported, and has no supported wrapper. `ops/windows/server/shutdown_all.bat` is a
fail-closed tombstone that performs no process or database action.

## Consequences

- A title mismatch cannot silently stop the wrong console.
- Already-stopped components are treated deterministically.
- Deployment scripts reference backups and configs owned elsewhere instead of embedding them.
- Process operations remain separately authorized even when helper tests have passed.

## Evidence

- `runbooks/shutdown-helper-console-lab/`
- `runbooks/world-shutdown-smoke-evidence-20260828-160724-135/`
- Earlier passing Windows evidence: `runbooks/external-evidence/DEPLOY-SHUTDOWN-HELPER-REALMD-01/`
- Later headless failure: `runbooks/ssc-source-baseline-02c-20260829-233607/`
- Historical Windows helper: `ops/windows/server/shutdown-tortoise-servers-gracefully.ps1`
- Supported implementation: `deploy/docker/entrypoint-mangosd.sh`
- Shutdown smoke contract: `test/smoke/40-shutdown.sh`
