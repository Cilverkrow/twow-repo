# ADR-0007: Forward migrations with verified backup and rollback

- Status: Accepted
- Date: 2026-08-29
- Primary: WS-20 / WS-60

## Context

The private server uses live MariaDB schemas, migration trackers with mixed provenance, and runtime code that may fail hard when its expected schema is missing. Editing base SQL or improvising tables would hide the relationship between source and schema.

## Decision

Database changes use reviewed forward migrations. Existing base SQL and historical migration files are not rewritten to simulate provenance.

Before applying a migration:

1. pin the exact source bytes and target schema;
2. stop dependent server processes in a controlled maintenance window;
3. create and verify the required logical or physical backup without exposing credentials;
4. run exact pre-state queries and abort on drift;
5. apply only the approved migration;
6. verify affected-row counts, schema, post-state, and restart behavior;
7. preserve a separate rollback plan or verified database restore path.

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
