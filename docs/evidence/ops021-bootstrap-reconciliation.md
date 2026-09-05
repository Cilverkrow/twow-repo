# OPS-021 pinned-core bootstrap reconciliation

Platform baseline: `80ec92e61dd2b30688342199c7806a8493ab9631`.
Core gitlink and lock: `e3ab7b0d7e77fc32009c664618d7ec7e58c511de`.
Tracking: issue #177. This change does not authorize a production migration.

The prior disposable runtime reached `SpellMgr::LoadSpellExtra` and aborted on
missing `tw_world.spell_extra`, although db-init had returned success. Platform
`sql/create_databases.sql` lacks the table that the pinned core defines, and the
platform world migration stream omits seven committed core migrations:

| Core path below `sql/` | Coverage |
| --- | --- |
| `database_updates/20260611110845_world.sql` | Create/populate `spell_extra` from `spell_template` |
| `database_updates/20260817211652_world.sql` | Northwind quest content |
| `database_updates/world/20260825052735_world.sql` | Spell content |
| `database_updates/world/20260826183610_world.sql` | World content |
| `database_updates/world/20260829145107_world.sql` | World content |
| `database_updates/world/20260829172251_world.sql` | World content |
| `database_updates/world/20260829175114_world.sql` | Pickpocketing content |

The only normalized schema-definition difference is the added `spell_extra`
table. All 190 base files agree byte-for-byte. Six shared migration files differ
only in CRLF/LF representation. The platform-only persistent-roster migration
must remain included; switching every input blindly to core would omit it.

Bootstrap now reads core's schema and base, and resolves a chronological union
of core/platform migrations. Shared names must have identical content after
CRLF/LF comparison; their existing platform bytes remain the ledger source.
Other differences fail before any DB connection. Missing directories fail too.
No source SQL or core pin is modified. `wip_updates` remains excluded.

Core's character index migration `20260708055500_ai_playerbot_random_bots_index`
is deferred until the PlayerBot table exists, then its actual SQL is applied
and its own SHA-1 recorded. With PlayerBots disabled it is not recorded.
This changes neither registry admission nor roster membership or activation.

An existing exact ledger entry suppresses re-execution; a changed digest or
multiple entries fails. A failed SQL client is never followed by registration.
The final check executes the six-column projection used by the pinned loader.

## Validation contract

`test/smoke/bootstrap-stream-contract.sh` tests chronological union, EOL-only
deduplication, conflicting content and missing directories without a server.
`test/smoke/core-schema-bootstrap.sh` runs only inside a fresh task-owned MariaDB
container with `/work` mounted read-only. It checks every selected migration's
exact SHA-1 and complete tracker count, nonempty `spell_extra`, full logical-dump
SHA-256 equality on replay, and replay after removing only the update-stage
marker. `bootstrap-ledger-contract.sh` uses a separate disposable test schema
to prove SQL failure, at-most-once execution and digest-conflict rejection.
The CI bootstrap job checks out core and runs coverage and resolver gates.

Local validation on 2026-09-05 used `mariadb:11.8` image digest
`sha256:2439dcd7d14010ecd1ff7a4e1c5abe8e208c34fe35290744deeeaac3569043c3`,
with network disabled, no published port and task-only tmpfs data/state.
The final frozen bootstrap run passed: 152 world, five character and one logon
ledger entries matched the selected migration bytes; `spell_extra` contained
27,917 rows and the roster member table remained empty. Full database replay
SHA-256 was `4a3d02cad63831ce2ed503e4b9e2be6665eebc6b4c5821dd60478c1a95d2fc63`;
both normal replay and interrupted-update replay preserved that digest.
Resolver negatives, failed-SQL/no-registration, non-idempotent SQL at-most-once,
wrong-ledger-hash and missing-core-input gates passed. Bash parsing, Compose
configuration validation, ShellCheck 0.11.0 at warning severity and diff checks
passed. No world/auth executable was compiled or started.

Development run 1 passed the initial fresh/replay test. Development run 2
passed schema/ledger coverage but failed reading a bind-mounted script while
that script was being edited; it is not counted as a passing replay. Final run
3 used the frozen bootstrap and passed completely. Raw local logs are retained
under the task's authorized Y: output directory, outside Git. Client warnings
about passwordless-login TLS verification were recorded; no unexpected SQL
error occurred in the final positive run. The negative test intentionally
queries a nonexistent table in its own test schema.

## Existing volumes and follow-up

This is a fresh-bootstrap correction, not an in-place upgrade procedure.
Never remove schema/base/module stage markers on a populated database: those
stages contain destructive CREATE/DROP input. An old completed state lacking
`spell_extra` fails the final loader projection; it is not silently repaired.
Existing-volume reconciliation requires a separate backup and migration plan.
Task-owned disposable resources may be discarded; no production rollback is
performed. Reverting the platform commit restores the old bootstrap inputs but
does not undo any database DDL/data changes.

A full OPS-021 runtime retest remains separate: no world/auth process, client
data, roster apply, Phase C or LLM enablement is needed for these DB tests.
