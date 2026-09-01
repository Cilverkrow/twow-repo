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
# Claim 3 used to be a warning, because deploy/compose/db-init.sh wrote 'manual'
# on purpose and argued its case: sql/base is a mixed snapshot rather than "the
# first N migrations applied", so there was supposedly no honest per-file digest
# to record. OPS-020 removed the premise. The bootstrap now applies each file on
# its own, records it only if the client exited 0, and records the uppercase
# SHA-1 of the file's bytes - the same digest the AutoUpdater computes. A
# 'manual' row can therefore only come from a database bootstrapped by the old
# script, and it means exactly what ADR-0024 invariant 3 and FG-033 say it means:
# a row nobody can check against a file.
#
# So it fails by default now, and agrees with the CI check that rejects 'manual'
# in new .sql files. An operator carrying an old volume can downgrade it to the
# old warning while they rebuild:
#
#     TWOW_STRICT_MIGRATION_HASHES=0 sh test/smoke/10-migrations.sh
#
# Like 15-schema-effects.sh it needs nothing but the database, which is why both
# still run in CI where there is no client data.
set -eu
# shellcheck source=test/smoke/lib.sh
. "$(dirname "$0")/lib.sh"

: "${TWOW_STRICT_MIGRATION_HASHES:=1}"

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
        # Name the gap rather than just the symptom. db-init.sh records a row
        # where it applies a file, so an empty ledger for a schema that has
        # migration files on disk means the applying stage never reached it.
        fail "$schema.migrations is empty - the bootstrap applied nothing to it (see stage 30-updates in deploy/compose/db-init.sh)"
    fi
    info "$schema.migrations rows: $rows"
    total=$(( total + rows ))

    manual=$(dbq "$schema" "SELECT COUNT(*) FROM \`migrations\` WHERE \`Hash\`='manual';") || fail "database query failed"
    if [ "${manual:-0}" -gt 0 ]; then
        manual_total=$(( manual_total + manual ))
        info "WARN $schema.migrations has $manual rows hashed 'manual' (ADR-0024 invariant 3, FG-033, OPS-012)"
        info "     nothing writes those any more - this database predates the OPS-020 fix and wants rebuilding"
    fi
done

if [ "$manual_total" -gt 0 ] && [ "$TWOW_STRICT_MIGRATION_HASHES" = "1" ]; then
    fail "$manual_total ledger rows carry the literal hash 'manual' and strict mode is on"
fi

if [ "$manual_total" -gt 0 ]; then
    pass "$total migration rows across $LEDGER_SCHEMAS ($manual_total hashed 'manual' - see the warning above)"
fi

pass "$total migration rows across $LEDGER_SCHEMAS, every hash a real digest"
