#!/usr/bin/env bash
# Integration negatives in a dedicated test schema, inside the isolated container.
set -euo pipefail
test "${BOOTSTRAP_DISPOSABLE_TEST:-}" = YES
export MYSQL_PWD="${MARIADB_ROOT_PASSWORD:?}"
mysql_root() { mariadb -h 127.0.0.1 -P 3306 -uroot "$@"; }
log() { printf '%s\n' "$*" >&2; }
export STATE=/state
# Only the two tested definitions are loaded, never the bootstrap entry point.
# shellcheck source=/dev/null
source <(sed -n '/^migration_hash() /p; /^apply_migration() {$/,/^}$/p' /work/deploy/compose/db-init.sh)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mysql_root -e 'CREATE DATABASE bootstrap_failure_test;
    CREATE TABLE bootstrap_failure_test.migrations (Name VARCHAR(255), Hash VARCHAR(40), AppliedAt TIMESTAMP);'
printf 'SELECT * FROM nonexistent_bootstrap_test_table;\n' > "$scratch/invalid.sql"
if (apply_migration bootstrap_failure_test "$scratch/invalid.sql"); then
    echo 'Failed SQL was accepted' >&2; exit 1
fi
test "$(mysql_root -NB -e 'SELECT COUNT(*) FROM bootstrap_failure_test.migrations')" = 0
echo 'FAILED_SQL_NOT_RECORDED=PASS'
printf 'CREATE TABLE exactly_once (id INT PRIMARY KEY); INSERT INTO exactly_once VALUES (1);\n' > "$scratch/valid.sql"
(apply_migration bootstrap_failure_test "$scratch/valid.sql")
(apply_migration bootstrap_failure_test "$scratch/valid.sql")
test "$(mysql_root -NB -e 'SELECT COUNT(*) FROM bootstrap_failure_test.exactly_once')" = 1
echo 'RECORDED_NONIDEMPOTENT_SQL_NOT_REEXECUTED=PASS'
mysql_root -e "UPDATE bootstrap_failure_test.migrations SET Hash=REPEAT('0',40);"
if (apply_migration bootstrap_failure_test "$scratch/valid.sql"); then
    echo 'Wrong ledger hash was accepted' >&2; exit 1
fi
echo 'LEDGER_HASH_CONFLICT_REJECTED=PASS'
