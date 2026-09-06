#!/usr/bin/env bash
# Run inside a task-owned MariaDB container; never targets a host database.
set -euo pipefail
export DB_HOST=127.0.0.1 DB_PORT=3306
export DB_ROOT_PASSWORD="$MARIADB_ROOT_PASSWORD"
export DB_USER=bootstrap_test DB_PASSWORD="$MARIADB_ROOT_PASSWORD"
export REALM_NAME=BootstrapTest REALM_ADDRESS=127.0.0.1 WORLD_PORT=8090
export SQL_DIR=/work/core/sql CORE_SQL_DIR=/work/core/sql
export SQL_BASE_DIR=/work/core/sql/base PB_SQL_DIR=/work/core/modules/mod-playerbots/sql
export PB_OVERLAY_SQL_DIR=/work/deploy/sql/playerbots
export IMPORT_PLAYERBOTS=ON MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
sql() { mariadb -h 127.0.0.1 -P 3306 -uroot -NB "$@"; }
for _ in $(seq 1 60); do
    sql -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
done
test "$(sql -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME IN ('tw_world','tw_char','tw_logon','tw_logs','cv_bots')")" = 0
bash /work/deploy/compose/db-init.sh
sql -e 'SHOW CREATE TABLE tw_world.spell_extra; SELECT COUNT(*) FROM tw_world.spell_extra;'
test "$(sql -e 'SELECT COUNT(*) FROM tw_world.spell_extra')" -gt 0
bash /work/test/smoke/verify-bootstrap-coverage.sh
snapshot() {
    mariadb-dump -h 127.0.0.1 -P 3306 -uroot --skip-comments --skip-dump-date \
        --skip-extended-insert --order-by-primary --databases tw_world tw_char tw_logon tw_logs cv_bots | sha256sum
}
before=$(snapshot)
bash /work/deploy/compose/db-init.sh
after=$(snapshot)
test "$before" = "$after"
printf 'FULL_DATABASE_REPLAY_SHA256=%s\n' "$after"
# Simulate an interrupted migration stage without replaying DROP/CREATE stages.
rm /state/30-updates
bash /work/deploy/compose/db-init.sh
test "$before" = "$(snapshot)"
echo 'INTERRUPTED_UPDATE_REPLAY=PASS'
printf 'CORE_SCHEMA_BOOTSTRAP_TEST=PASS\n'
