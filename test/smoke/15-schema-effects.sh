#!/bin/sh
# Proves: the schema changes the ledger claims were applied are actually there.
#
# 10-migrations.sh counts ledger rows. That is not the same question. A row says
# "this file was applied"; it does not say the file did anything, and until
# OPS-020 was fixed the bootstrap wrote rows for files that had failed outright
# (deploy/compose/db-init.sh recorded a row per filename in a stage that ran
# after the applying stage, unconditionally). The database then disagreed with
# its own ledger and nothing noticed for months.
#
# So this check goes the other way round: pick the schema changes whose absence
# was actually observed in CI, and look for them in information_schema. Each one
# below is a migration that DID fail silently, not a hypothetical.
#
#   1. idx_owner_bot_event on ai_playerbot_random_bots. The migration adding it
#      ran in the updates stage, one stage before the playerbot tables were
#      created, so on a fresh database it failed with ERROR 1146 every single
#      time - and was recorded as applied every single time. It now ships as
#      modules/mod-playerbots/sql/characters/ai_playerbot_random_bots_index.sql,
#      beside the CREATE it depends on.
#   2. spell_template.script_name in the world schema. Four top-level world
#      migrations write that column and the migration that ADDS it lives in
#      sql/database_updates/world/, which the bootstrap used to apply second.
#      All four failed on the missing column; all four were recorded as applied.
#
# Composite indexes are checked by their column list and order, not by name. The
# point of idx_owner_bot_event is that (owner, bot, event) turns a range scan
# into a point lookup, so an index of that name over the wrong columns would be
# a pass that proves nothing.
#
# Needs nothing but the database, like 10-migrations.sh, so it runs in CI where
# there is no client data.
set -eu
# shellcheck source=test/smoke/lib.sh
. "$(dirname "$0")/lib.sh"

require_stack

# --- 1. the composite index on the playerbot random-bot table ----------------

table_exists=$(dbq information_schema \
    "SELECT COUNT(*) FROM TABLES
      WHERE TABLE_SCHEMA='$TWOW_CHAR_SCHEMA' AND TABLE_NAME='ai_playerbot_random_bots';") \
    || fail "database query failed"
[ "${table_exists:-0}" = "1" ] \
    || fail "$TWOW_CHAR_SCHEMA.ai_playerbot_random_bots is missing - the playerbot schema never loaded"

# GROUP_CONCAT over SEQ_IN_INDEX gives the index as the optimiser sees it:
# leading column first. Comparing that string is what makes a renamed or
# reordered index a failure rather than a pass.
cols=$(dbq information_schema \
    "SELECT COALESCE(GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX),'')
       FROM STATISTICS
      WHERE TABLE_SCHEMA='$TWOW_CHAR_SCHEMA'
        AND TABLE_NAME='ai_playerbot_random_bots'
        AND INDEX_NAME='idx_owner_bot_event';") || fail "database query failed"

if [ -z "$cols" ]; then
    fail "idx_owner_bot_event is missing from $TWOW_CHAR_SCHEMA.ai_playerbot_random_bots -\
 its migration did not apply (OPS-020); RandomPlayerbotMgr::SetEventValue will gap-lock and deadlock"
fi
[ "$cols" = "owner,bot,event" ] \
    || fail "idx_owner_bot_event covers ($cols), not (owner,bot,event) - the point lookup it exists for is gone"
info "idx_owner_bot_event on $TWOW_CHAR_SCHEMA.ai_playerbot_random_bots covers ($cols)"

# --- 2. the column four world migrations write -------------------------------

script_name=$(dbq information_schema \
    "SELECT COUNT(*) FROM COLUMNS
      WHERE TABLE_SCHEMA='$TWOW_WORLD_SCHEMA'
        AND TABLE_NAME='spell_template' AND COLUMN_NAME='script_name';") \
    || fail "database query failed"
[ "${script_name:-0}" = "1" ] \
    || fail "$TWOW_WORLD_SCHEMA.spell_template.script_name is missing - the world migration stream did not apply in order"

# The column existing is necessary but not sufficient: it is added empty, and the
# four migrations that populate it are the ones that used to fail. A count of
# zero means the column landed and every writer of it did not.
scripted=$(dbq "$TWOW_WORLD_SCHEMA" \
    "SELECT COUNT(*) FROM \`spell_template\` WHERE \`script_name\` <> '';") \
    || fail "database query failed"
[ "${scripted:-0}" -gt 0 ] \
    || fail "no spell_template row carries a script_name - the migrations that assign them did not apply"
info "$TWOW_WORLD_SCHEMA.spell_template: $scripted rows carry a script_name"

pass "the schema changes the ledger claims are present in the database"
