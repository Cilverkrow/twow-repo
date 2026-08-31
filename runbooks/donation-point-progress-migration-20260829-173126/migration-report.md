# Donation Point Progress Migration Report

`DONATION_MIGRATION_RESULT=ABORTED`

## Outcome

The migration did not reach MariaDB startup. The final mandatory gate failed
because the Windows PowerShell 5.1 process was not elevated:

```text
This runbook requires an elevated Windows PowerShell 5.1 session.
```

No UAC request, privilege workaround, database start, logical dump, SQL client
operation, or migration execution was attempted after that gate failure.

## Approved source

- Path: `C:\TW\ComTW\source\sql\logon\donation_point_progress.sql`
- Bytes: `630`
- SHA-256: `EDD4D4BCD78AA8DA96179797C54B375477DBEA4DCA6CF06ECB3925F122248103`
- Unique matching filename under `C:\TW`: yes, exactly one
- Static executable-statement count: one
- Static statement identity: exact approved `CREATE TABLE IF NOT EXISTS`
- `COMMENT_DEFECT_RECORDED`

## Database and backup

- Intended database: `tw_logon`
- Database startup reached: no
- `SELECT DATABASE()` executed: no
- Pre-migration live schema inspection: not performed
- Backup created: no
- Migration client invoked: no
- Post-migration live schema inspection: not performed
- Physical `donation_point_progress.*` files after abort: zero

## Final state

- `mysqld`/`mariadbd`: zero
- `mangosd`: zero
- `realmd`: zero
- Matching running Windows services: zero
- Port 3307 listeners: zero
- Port 3724 listeners: zero
- Port 8090 listeners: zero
- Ollama PID 5528 remained untouched; port 11434 listeners: zero

No compile, executable replacement, configuration change, game-server start,
LLM operation, Honor operation, dump, unrelated migration, or SQL operation
was performed by the migration harness.

## Concurrent external state drift

The active `mangosd.conf` changed outside the migration harness between the
task's initial and final read-only identity checks:

- Initial: 69,531 bytes / `90D6D7AE3CC7AF9216F8B17F21E5762C1ED9D39DCC329234832123BAB0D618FF`
- Final: 69,515 bytes / `C552BA61CD6C4246198A041F7A5E3FB77931E2A23817FCF20B359751D219297D`
- Final LastWriteTimeUtc: `2026-08-29T15:38:43.2579727Z`

The current AutoDonationPoints values remained `Enable=1`, interval 3,600,000,
amount 100, and flush interval 300,000. No process referencing either active
configuration file was found. This evidence records the drift without assigning
its cause or modifying the file.
