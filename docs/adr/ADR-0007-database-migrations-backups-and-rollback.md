# ADR-0007: Forward migrations with verified backup and rollback

- Status: Accepted; **amended 2026-09-03** - the seven-step gate now applies to irreversible operations only, not to routine forward migrations.
- Date: 2026-08-29
- Primary: WS-20 / WS-60

## Context

The private server uses live MariaDB schemas, migration trackers with mixed provenance, and runtime code that may fail hard when its expected schema is missing. Editing base SQL or improvising tables would hide the relationship between source and schema.

## Decision

Database changes use reviewed forward migrations. Existing base SQL and historical migration files are not rewritten to simulate provenance.

**Routine forward migrations need no gate.** The core's `AutoUpdater` applies them at
`core/src/game/World.cpp:1953`, inside `SetInitialWorldSettings()` and *before* the ~122
`Load*` calls that read the world into memory. A forward migration therefore lands on a
database nothing has cached yet, and a failure calls `exit(1)` rather than running on. It
records each file as `Module:SHA1(bytes)` in the `migrations` ledger, so re-running is a
no-op. Nothing below applies to them.

**Backups are taken online.** InnoDB supports `mariabackup` for a hot physical copy and
`mysqldump --single-transaction` for a consistent logical snapshot without locking.
Stopping the server to take a backup was an artefact of the hand-applied Windows era and
is not required.

**Irreversible operations keep the gate**, and the reason is architectural rather than
about any operating system. `World.cpp` makes ~122 `Load*` calls at startup, and only a
handful of tables have a `.reload` chat command. Dropping or rewriting a table under a
running server therefore leaves it serving stale in-memory data while the database says
something else - silent divergence, no error. So before a drop, a data rewrite, a manual
rollback, or any change to a table the server has cached:

1. pin the exact source bytes and target schema;
2. create and verify a restorable backup, online, without exposing credentials;
3. run exact pre-state queries and abort on drift;
4. apply only the approved change;
5. verify affected-row counts, schema and post-state;
6. **restart the server**, because it will otherwise keep serving what it loaded;
7. preserve a rollback plan or a verified restore path.
Database migration, backup restore, and rollback are distinct authorized operations. `IF NOT EXISTS` is not proof of success: exact already-target state may be recognized, while any third state blocks the task. Historic tracker value `manual` is a label, not a cryptographic content hash.

## Consequences

- Source/schema mismatch is diagnosed before runtime use.
- Rollback authority is the verified backup or a separately reviewed forward rollback migration.
- Runtime backups are not mixed with append-only source migrations.
- Credentials remain outside scripts, reports, command history, and Git.

## Evidence

- `runbooks/donation-point-migration-20260829-183829/`
- `runbooks/ssc-source-baseline-02a2-20260829-213222/tracker-source-parity-report.md`
- `runbooks/db-profession-riding-discovery-01-20260830-010856/proposed-migration-plan.md`
