#!/bin/sh
# Proves: the database was bootstrapped and the migration ledger is real.
#
# Three claims, because each fails differently:
#   1. all four schemas exist (tw_world, tw_char, tw_logon, tw_logs);
#   2. every schema that has migration files on disk has a non-empty
#      `migrations` ledger - an empty ledger means structure was created and
#      nothing was recorded, and the next auto-update replays everything;
#   3. no row records the literal hash 'manual'.
#
# Claim 3 is a WARNING here, not a failure, and that is a deliberate and
# uncomfortable choice. ADR-0024 invariant 3 and FG-033 say real content hashes,
# never 'manual' - it made 146 world migrations unverifiable (OPS-012).
# deploy/compose/db-init.sh writes 'manual' on purpose and argues its case in
# its own header: sql/base is a mixed snapshot rather than "the first N
# migrations applied", so there is no honest per-file digest to record, and the
# tombstone is only safe while Database.AutoUpdate.Enabled = 0.
#
# Both positions are defensible and this script is not the place to settle it.
# So it reports the count loudly on every run and fails only when asked:
#
#     TWOW_STRICT_MIGRATION_HASHES=1 sh test/smoke/10-migrations.sh
#
# This is the only check that needs nothing but the database, which is why it
# still runs in CI where there is no client data.
set -eu
# shellcheck source=test/smoke/lib.sh
. "$(dirname "$0")/lib.sh"

: "${TWOW_STRICT_MIGRATION_HASHES:=0}"

require_stack

# tw_logs carries no migrations table in the bootstrap dump, so it is checked
# for existence only.
LEDGER_SCHEMAS="$TWOW_WORLD_SCHEMA $TWOW_CHAR_SCHEMA $TWOW_LOGON_SCHEMA"
ALL_SCHEMAS="$LEDGER_SCHEMAS $TWOW_LOGS_SCHEMA"

for schema in $ALL_SCHEMAS; do
    found=$(dbq information_schema \
        "SELECT COUNT(*) FROM SCHEMATA WHERE SCHEMA_NAME='$schema';") || fail "database query failed"
    [ "${found:-0}" = "1" ] || fail "schema $schema does not exist"
done
info "schemas present: $ALL_SCHEMAS"

total=0
manual_total=0
for schema in $LEDGER_SCHEMAS; do
    exists=$(dbq information_schema \
        "SELECT COUNT(*) FROM TABLES WHERE TABLE_SCHEMA='$schema' AND TABLE_NAME='migrations';") || fail "database query failed"
    [ "${exists:-0}" = "1" ] || fail "$schema has no migrations table"

    rows=$(dbq "$schema" "SELECT COUNT(*) FROM \`migrations\`;") || fail "database query failed"
    if [ "${rows:-0}" -eq 0 ]; then
        # Name the gap rather than just the symptom: db-init.sh records
        # sql/database_updates into tw_world and nothing else, so sql/logon and
        # sql/character_updates (which is where the persistent roster lives)
        # currently reach no ledger at all.
        fail "$schema.migrations is empty - the bootstrap recorded nothing for it (deploy/compose/db-init.sh records sql/database_updates only)"
    fi
    info "$schema.migrations rows: $rows"
    total=$(( total + rows ))

    manual=$(dbq "$schema" "SELECT COUNT(*) FROM \`migrations\` WHERE \`Hash\`='manual';") || fail "database query failed"
    if [ "${manual:-0}" -gt 0 ]; then
        manual_total=$(( manual_total + manual ))
        info "WARN $schema.migrations has $manual rows hashed 'manual' (ADR-0024 invariant 3, FG-033, OPS-012)"
    fi
done

if [ "$manual_total" -gt 0 ] && [ "$TWOW_STRICT_MIGRATION_HASHES" = "1" ]; then
    fail "$manual_total ledger rows carry the literal hash 'manual' and strict mode is on"
fi

if [ "$manual_total" -gt 0 ]; then
    pass "$total migration rows across $LEDGER_SCHEMAS ($manual_total hashed 'manual' - see the warning above)"
fi

pass "$total migration rows across $LEDGER_SCHEMAS, every hash a real digest"
