#!/bin/sh
# Proves: ADR-0024 invariant 1 - a bot must never be lost.
#
# "A bot keeps its character, GUID, items, progression, relationships and history
# across restarts." That sentence is only worth anything if something restarts
# the stack and compares. This is that something, and it is the reason the smoke
# suite exists rather than being a nice-to-have.
#
# The method: read the current roster version and every member's identity and
# progression, save and restart the world server, read it again, require the two
# to be byte-identical. Not "similar", not "the same count" - identical. A
# re-rolled cohort has the same count, which is exactly how FG-044 hid.
#
# What is compared per member: ordinal, character GUID, name, level, xp, money
# and inventory row count. Plus the roster version id itself, because advancing
# it across a plain restart would mean the roster was rewritten, which no
# restart may ever do.
#
# It fails - it does not skip - when the roster is empty. An unpopulated roster
# means this invariant went unproven, and reporting that as a pass is the exact
# failure this file is written to prevent.
set -eu
. "$(dirname "$0")/lib.sh"

require_stack
require_client_data

work=$(mktemp -d)
# shellcheck disable=SC2064  # expand $work now: it is gone by the time this runs
trap "rm -rf '$work'" EXIT INT TERM

tables=$(dbq information_schema \
    "SELECT COUNT(*) FROM TABLES WHERE TABLE_SCHEMA='$TWOW_CHAR_SCHEMA'
     AND TABLE_NAME IN ('ai_playerbot_roster_current','ai_playerbot_roster_version','ai_playerbot_roster_member');") || fail "database query failed"
[ "${tables:-0}" = "3" ] \
    || fail "the persistent roster schema is not present in $TWOW_CHAR_SCHEMA - invariant 1 is unenforceable"

# The immutable, ordered, versioned membership snapshot the current pointer
# names. LEFT JOIN, not JOIN: a member whose character row has vanished is
# precisely the loss being tested for, and an inner join would hide it.
snapshot() {
    dbq "$TWOW_CHAR_SCHEMA" "
        SELECT m.\`ordinal\`, m.\`character_guid\`,
               COALESCE(c.\`name\`,'<MISSING>'), COALESCE(c.\`level\`,-1),
               COALESCE(c.\`xp\`,-1), COALESCE(c.\`money\`,-1),
               (SELECT COUNT(*) FROM \`character_inventory\` i WHERE i.\`guid\` = m.\`character_guid\`)
        FROM \`ai_playerbot_roster_member\` m
        JOIN \`ai_playerbot_roster_current\` cur ON cur.\`version_id\` = m.\`version_id\`
        LEFT JOIN \`characters\` c ON c.\`guid\` = m.\`character_guid\`
        WHERE cur.\`singleton_id\` = 1
        ORDER BY m.\`ordinal\`;"
}

version_before=$(dbq "$TWOW_CHAR_SCHEMA" \
    "SELECT COALESCE(\`version_id\`,0) FROM \`ai_playerbot_roster_current\` WHERE \`singleton_id\`=1;") || fail "database query failed"
[ "${version_before:-0}" != "0" ] \
    || fail "no current roster version - the roster is empty, so invariant 1 went unproven"

snapshot > "$work/before" || fail "could not read the roster"
members=$(wc -l < "$work/before" | tr -d ' ')
[ "${members:-0}" -gt 0 ] \
    || fail "roster version $version_before has no members - invariant 1 went unproven"
if grep -q '<MISSING>' "$work/before"; then
    fail "a roster member has no character row before the restart - a bot is already lost"
fi
info "roster version $version_before, $members members"

# saveall first: the point is to prove persistence, not to prove that an
# unsaved world happens to survive. The entrypoint does this on SIGTERM too;
# doing it explicitly makes the failure attributable if it does not.
dc exec -T "$TWOW_WORLD_SERVICE" sh -c "printf 'saveall\n' > '$TWOW_FIFO'" \
    || fail "could not write 'saveall' to the console FIFO"
sleep 5

info "restarting $TWOW_WORLD_SERVICE"
dc restart -t 90 "$TWOW_WORLD_SERVICE" >/dev/null 2>&1 \
    || fail "restart of $TWOW_WORLD_SERVICE failed"

world_up() { tcp_probe "$TWOW_HOST" "$TWOW_WORLD_PORT"; }
wait_for "$TWOW_TIMEOUT" world_up \
    || fail "$TWOW_WORLD_SERVICE did not come back on $TWOW_WORLD_PORT within ${TWOW_TIMEOUT}s"

version_after=$(dbq "$TWOW_CHAR_SCHEMA" \
    "SELECT COALESCE(\`version_id\`,0) FROM \`ai_playerbot_roster_current\` WHERE \`singleton_id\`=1;") || fail "database query failed"
[ "$version_after" = "$version_before" ] \
    || fail "roster version changed across a restart: $version_before -> $version_after (the roster was rewritten)"

snapshot > "$work/after" || fail "could not read the roster after the restart"

if ! diff -u "$work/before" "$work/after" > "$work/diff" 2>&1; then
    printf '     %-20s roster differs across the restart:\n' "$smoke_name"
    sed 's/^/       /' "$work/diff"
    fail "ADR-0024 invariant 1 VIOLATED: $members bots did not survive the restart identically"
fi

pass "invariant 1 holds: roster version $version_after, all $members bots identical across a restart"
