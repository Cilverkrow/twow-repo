# OPS-001 read-only bot-population matrix

- Issue: `OPS-001` / GitHub issue `#23`
- Workstream: `WS-30`
- Result: `BLOCKED`
- Failure code: `EXISTING_PRINCIPAL_NOT_SELECT_ONLY`

## Enforced boundary

The intended MariaDB binary and client/admin binaries were SHA-256 pinned before start. No Windows database service was started. The direct process, its executable path, PID, command line, sole loopback listener, and configured schemas were checked before any connection. `mangosd` and `realmd` remained stopped and were never controlled.

Credentials were read only in memory from the existing local configuration and supplied only through a newly created inheritance-disabled, current-SID-only option file. Raw grants and client/server stderr were never persisted or printed. Temporary option files were removed during cleanup.

## Capture outcome

The effective-grant gate found privilege outside the permitted `USAGE` / `SELECT` / `SHOW VIEW` set. Per authorization, execution stopped before every issue query. No raw grant text or principal identity was retained. Issue #23 remains open until an existing SELECT-only principal is provided.

The persisted candidate count is separate from the runtime set: with `mangosd` stopped, `RUNTIME_GROUP_LOGIN_CANDIDATE_COUNT` is not observable and is not inferred as zero.

## Final containment

- MariaDB stopped: `YES`
- `mangosd` stopped: `YES`
- `realmd` stopped: `YES`
- Port 3307 listener absent: `YES`
- Graceful MariaDB shutdown: `YES`
- Targeted-stop fallback used: `NO`

No domain INSERT, UPDATE, DELETE, REPLACE, DDL, migration, GRANT, or configuration operation was issued.
