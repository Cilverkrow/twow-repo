# LOGIN schema readiness

## Connection identity

The active `mangosd.conf` key is `LoginDatabase.Info`. It resolves to:

- Host: `127.0.0.1`
- Port: `3307`
- Database: `tw_logon`
- Credential fields: present
- Credential values: intentionally not recorded

Installed client/server version: MariaDB 11.4.10. The supplied DDL uses supported
`CREATE TABLE IF NOT EXISTS`, InnoDB, `INT UNSIGNED`, and utf8mb4 syntax.

## Supplied SQL

- Path: `C:\TW\ComTW\source\sql\logon\donation_point_progress.sql`
- Bytes: 630
- SHA-256: `EDD4D4BCD78AA8DA96179797C54B375477DBEA4DCA6CF06ECB3925F122248103`
- Expected database: `tw_logon`
- Table: `donation_point_progress`

Complete sanitized DDL:

```sql
CREATE TABLE IF NOT EXISTS `donation_point_progress` (
  `account_id`     INT UNSIGNED NOT NULL PRIMARY KEY,
  `accumulated_ms` INT UNSIGNED NOT NULL DEFAULT 0
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

The table has two columns, one primary BTREE key on `account_id`, no foreign key,
and no secondary index. `CREATE TABLE IF NOT EXISTS` is idempotent only when the
table is absent or already correct; it does not repair or reject schema drift and
must not replace an explicit preflight comparison.

The authoritative bootstrap SQL defines:

- `account.id`: `INT UNSIGNED NOT NULL AUTO_INCREMENT`, primary key.
- `shop_coins.id`: `INT UNSIGNED NOT NULL`, primary BTREE key.
- `shop_coins.coins`: `INT NOT NULL DEFAULT 0`.
- `shop_coins`: InnoDB, utf8mb3/utf8mb3_general_ci, dynamic row format.

## Current offline findings

MariaDB was not running and port 3307 was closed. No SQL was executed.

Physical files found under `DB\data\tw_logon`:

- `account.frm` and `account.ibd`
- `shop_coins.frm`, `shop_coins.ibd`, and trigger metadata
- no `donation_point_progress.*` file

Because file-per-table behavior and the live data dictionary were not queried,
physical absence is not promoted to an authoritative live-schema conclusion.

| Check | Result |
|---|---|
| `donation_point_progress` live existence | NOT PROVEN; physical files absent |
| Exact progress-table schema | NOT PROVEN |
| Progress row count or unexpected rows | NOT PROVEN |
| `shop_coins` live column definition | NOT PROVEN; official expected DDL recorded |
| `account` live key definition | NOT PROVEN; official expected DDL recorded |
| Schema drift | NOT PROVEN |

## Proposed live read-only gate — DO NOT RUN

After a separately authorized database start, use only `SELECT`, `SHOW`,
`DESCRIBE`, and `information_schema` to verify database identity, MariaDB version,
table existence, exact columns/defaults/nullability, primary/index definitions,
engine/collation, progress row count, and orphaned progress account IDs. Do not
return account IDs, names, balances, password material, or complete rows.

Abort activation if an existing table differs from the supplied DDL, if
`shop_coins.coins` differs from `INT NOT NULL DEFAULT 0`, or if required account
and shop primary keys are missing.
