#!/bin/sh
# Proves: `docker stop` is a graceful in-game shutdown, not a kill.
#
# The entrypoint traps SIGTERM, writes `saveall` and `server shutdown 0` to the
# console FIFO and waits, deliberately never escalating to SIGKILL - a hard kill
# here is how character and bot state gets truncated (ADR-0006, ADR-0023).
#
# Three things are asserted, because a broken shutdown can satisfy any two:
#   1. the container exits 0 (the entrypoint returned, it was not killed);
#   2. it logged the clean-shutdown line (the trap ran, it did not just die);
#   3. no character row is left flagged online (the world saved, not truncated).
#
# The stack is put back the way it was found, so this can be re-run and so it
# can sit last in run-all.sh without wrecking a developer's running stack.
set -eu
. "$(dirname "$0")/lib.sh"

require_stack
require_client_data

before=$(dbq "$TWOW_CHAR_SCHEMA" "SELECT COUNT(*) FROM \`characters\`;") || fail "database query failed"
info "character rows before shutdown: ${before:-unknown}"

since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 1

# `stop` sends SIGTERM and waits; the grace period must exceed the entrypoint's
# own MANGOSD_SHUTDOWN_GRACE or docker kills it and we would be testing docker.
dc stop -t 90 "$TWOW_WORLD_SERVICE" >/dev/null 2>&1 \
    || fail "docker compose stop of $TWOW_WORLD_SERVICE failed"

cid=$(dc ps -a -q "$TWOW_WORLD_SERVICE" | head -n 1)
[ -n "$cid" ] || fail "cannot resolve the $TWOW_WORLD_SERVICE container id"
code=$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo "?")
[ "$code" = "0" ] || fail "$TWOW_WORLD_SERVICE exited $code - shutdown was not clean"

dc logs --since "$since" "$TWOW_WORLD_SERVICE" 2>/dev/null | grep -q 'clean shutdown' \
    || fail "$TWOW_WORLD_SERVICE exited 0 but never logged '[entrypoint] clean shutdown'"

online=$(dbq "$TWOW_CHAR_SCHEMA" "SELECT COUNT(*) FROM \`characters\` WHERE \`online\` <> 0;") || fail "database query failed"
[ "${online:-1}" = "0" ] \
    || fail "$online characters still flagged online after shutdown - dirty state"

after=$(dbq "$TWOW_CHAR_SCHEMA" "SELECT COUNT(*) FROM \`characters\`;") || fail "database query failed"
[ "$after" = "$before" ] \
    || fail "character rows changed across shutdown: $before -> $after"

info "restarting $TWOW_WORLD_SERVICE to leave the stack as found"
dc start "$TWOW_WORLD_SERVICE" >/dev/null 2>&1 || true

pass "clean SIGTERM shutdown: exit 0, trap ran, 0 characters left online, $after rows intact"
