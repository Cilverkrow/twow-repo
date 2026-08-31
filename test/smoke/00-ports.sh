#!/bin/sh
# Proves: the two listeners a client actually connects to are accepting TCP.
#
# realmd on 3724 is the login server and needs no client data, so it is a hard
# requirement here. The world server on 8090 cannot start without maps, so it is
# checked only when client data is present - and skipped loudly when it is not.
set -eu
# shellcheck source=test/smoke/lib.sh
. "$(dirname "$0")/lib.sh"

require_stack

tcp_probe "$TWOW_HOST" "$TWOW_REALMD_PORT" \
    || fail "realmd is not accepting connections on $TWOW_HOST:$TWOW_REALMD_PORT"
info "realmd listening on $TWOW_HOST:$TWOW_REALMD_PORT"

if ! have_client_data; then
    skip "realmd:$TWOW_REALMD_PORT is up; worldserver:$TWOW_WORLD_PORT not checked - no client data mounted (ADR-0023)"
fi

tcp_probe "$TWOW_HOST" "$TWOW_WORLD_PORT" \
    || fail "worldserver is not accepting connections on $TWOW_HOST:$TWOW_WORLD_PORT"

pass "realmd:$TWOW_REALMD_PORT and worldserver:$TWOW_WORLD_PORT are accepting connections"
