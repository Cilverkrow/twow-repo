#!/bin/sh
# Proves: the world server's console FIFO is alive and the server answers on it.
#
# This is the container-specific failure the entrypoint exists to prevent.
# mangosd reads its console from stdin and treats EOF as "shut down", so a
# container without a TTY dies instantly; the entrypoint holds a FIFO open
# read-write for the container's lifetime instead (ADR-0023 blocker 3).
#
# A FIFO that exists but is not being read looks identical from outside - the
# write just blocks or vanishes. So this does not check for the file: it sends
# `server info` and requires the answer in the log.
set -eu
. "$(dirname "$0")/lib.sh"

require_stack
require_client_data

dc exec -T "$TWOW_WORLD_SERVICE" sh -c "[ -p '$TWOW_FIFO' ]" \
    || fail "no console FIFO at $TWOW_FIFO in the $TWOW_WORLD_SERVICE container"

# Timestamp first so only lines produced after the command are searched; the
# log almost certainly already contains an earlier "Players online:".
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 1

dc exec -T "$TWOW_WORLD_SERVICE" sh -c "printf 'server info\n' > '$TWOW_FIFO'" \
    || fail "could not write to the console FIFO at $TWOW_FIFO"

# "Players online:" is emitted by HandleServerInfoCommand and by nothing else,
# so it is an unambiguous acknowledgement rather than incidental log noise.
answered() {
    dc logs --since "$since" "$TWOW_WORLD_SERVICE" 2>/dev/null | grep -q 'Players online:'
}

wait_for 30 answered \
    || fail "wrote 'server info' to $TWOW_FIFO but the server never answered within 30s"

pass "console FIFO $TWOW_FIFO accepted 'server info' and the server answered"
