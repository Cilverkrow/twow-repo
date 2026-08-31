#!/bin/sh
# Proves: the database was bootstrapped and the migration ledger is real.
#
# Three separate claims, because each fails differently:
#   1. all four upstream schemas exist (tw_world, tw_char, tw_logon, tw_logs);
#   2. each carries a `migrations` table with at least one row - an empty ledger
#      means the bootstrap created structure and applied nothing;
#   3. no row records the literal hash 'manual'. ADR-0024 invariant 3 and FG-033:
#      'manual' made 146 world migrations unverifiable (OPS-012) and must never
#      reappear in a database this project builds from empty.
#
# This is the only check that needs nothing but the database, which is why it is
# also the one that still runs in CI where there is no client data.
set -eu
# shellcheck source=test/smoke/lib.sh
. "$(dirname "$0")/lib.sh"

require_stack

# tw_logs holds no migrations table of its own in the bootstrap dump, so it is
# checked for existence only.
LEDGER_SCHEMAS="$TWOW_WORLD_SCHEMA $TWOW_CHAR_SCHEMA $TWOW_LOGON_SCHEMA"
ALL_SCHEMAS="$LEDGER_SCHEMAS $TWOW_LOGS_SCHEMA"

for schema in $ALL_SCHEMAS; do
    found=$(dbq information_schema \
        "SELECT COUNT(*) FROM SCHEMATA WHERE SCHEMA_NAME='$schema';") || fail "database query failed"
    [ "${found:-0}" = "1" ] || fail "schema $schema does not exist"
done
info "schemas present: $ALL_SCHEMAS"

total=0
for schema in $LEDGER_SCHEMAS; do
    exists=$(dbq information_schema \
        "SELECT COUNT(*) FROM TABLES WHERE TABLE_SCHEMA='$schema' AND TABLE_NAME='migrations';") || fail "database query failed"
    [ "${exists:-0}" = "1" ] || fail "$schema has no migrations table"

    rows=$(dbq "$schema" "SELECT COUNT(*) FROM \`migrations\`;") || fail "database query failed"
    [ "${rows:-0}" -gt 0 ] 2>/dev/null \
        || fail "$schema.migrations is empty - the bootstrap applied no migrations"
    info "$schema.migrations rows: $rows"
    total=$(( total + rows ))

    manual=$(dbq "$schema" "SELECT COUNT(*) FROM \`migrations\` WHERE \`Hash\`='manual';") || fail "database query failed"
    [ "${manual:-0}" = "0" ] \
        || fail "$schema.migrations has $manual rows hashed 'manual' (ADR-0024 invariant 3, FG-033)"
done

pass "$total migration rows across $LEDGER_SCHEMAS, every hash a real digest"
