# ADR-0027: MariaDB is the single database platform

- Status: Proposed
- Date: 2026-08-31
- Primary: WS-20 / WS-30

## Context

The question of whether the project could move to PostgreSQL was raised. It is worth
answering definitively and recording, because a stale `DatabasePostgre.cpp` in the tree
makes the option look more open than it is.

Findings:

- A PostgreSQL backend exists in the source: `DatabasePostgre.{cpp,h}`,
  `QueryResultPostgre.{cpp,h}` and `PGSQLDelayThread.h`, all listed in
  `src/shared/CMakeLists.txt`. It is inherited MaNGOS code, unchanged since the initial
  upload of 2025-12-16, and gated on `DO_POSTGRESQL` — a macro that appears only inside
  `#ifdef` guards across ten files and **is never defined by any build file**. It has
  never been compiled in this project.
- The data is the real constraint. 161 files under `sql/base` declare `ENGINE=MyISAM`;
  36 files under `sql/database_updates` use `INSERT IGNORE` or `REPLACE INTO`;
  `create_databases.sql` is full of `AUTO_INCREMENT`; and all 190 base files are
  `mysqldump` output with backtick quoting and `LOCK TABLES`.
- `src/shared/Database/AutoUpdater.cpp` is MySQL-shaped, and commit `3c2b931` added
  MySQL-specific work to `DatabaseMysql` (`mysql_affected_rows`).

A migration would therefore mean rewriting 359 SQL files, the database layer, and the
auto-updater — for no benefit the project has asked for.

Separately, the memory work in ARCH-002 needs vector similarity search, which is the one
plausible reason to want PostgreSQL (pgvector). MariaDB 11.8 LTS closes that gap: it
provides a native `VECTOR(N)` type and `VECTOR INDEX` (HNSW) with `VEC_DISTANCE_COSINE()`,
up to 16,383 dimensions, under full ACID.

## Decision

MariaDB is the single database platform for the whole project — upstream schemas,
project module schemas, and any future service schema.

- Target **MariaDB 11.8 LTS or newer** everywhere. `INSTALL-LINUX.md` already verifies
  11.8; `ops/windows/build/compile-tortoise-wow.ps1:49` pins 11.4.10, which predates the
  `VECTOR` type. That divergence is a defect to fix, not a supported configuration.
- Vector storage for bot memory uses MariaDB's native `VECTOR` type. No separate vector
  database is introduced.
- The `DO_POSTGRESQL` path is documented as dead. It is not removed in this decision —
  deleting inherited upstream files widens the diff against upstream for no gain — but
  it must not be presented as a supported option.

## Consequences

- One database technology to operate, back up, migrate and test.
- The vector requirement does not add an operational component.
- Anyone proposing PostgreSQL now has the cost written down and does not need to
  rediscover it.
- Pinning 11.8 has a real cost: the Windows one-click build script must be updated, and
  MariaDB 11.8's default collation differs from older dumps
  (`utf8mb4_uca1400_ai_ci` versus `utf8mb3_general_ci`), which `INSTALL-LINUX.md`
  already documents as a source of "Illegal mix of collations".

## Evidence

- `src/shared/Database/DatabaseEnv.h`, `DatabasePostgre.cpp`, `src/shared/CMakeLists.txt`
- `sql/base/`, `sql/database_updates/`, `sql/create_databases.sql`
- `INSTALL-LINUX.md`, `ops/windows/build/compile-tortoise-wow.ps1`
- Commit `3c2b931` (`DatabaseMysql::AffectedRows`)
