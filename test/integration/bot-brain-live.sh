#!/usr/bin/env bash
# Proves: the real Go bot-brain service and the real C++ wire encoder/decoder
# agree over an actual TCP socket, and that killing the service produces a
# clean transport failure rather than a hang or a crash (issue #155).
#
# Nothing else has ever run these two together. services/bot-brain has 58 Go
# unit tests and modules/mod-bot-brain has a C++ suite, but each side only ever
# feeds itself inline or golden data - a field the encoder emits and the Go
# struct silently ignores would be green on both sides forever. This script is
# the check that would catch it: it starts the REAL service binary, drives it
# with JSON produced by the REAL C++ encoder (bot_brain_wire_tests
# --dump-request), and decodes the REAL response with the REAL C++ decoder
# (bot_brain_wire_tests --check-response). No world server, no database, no
# bot: see the "what this does NOT prove" note at the bottom.
#
# WHY THIS MUST FAIL WHEN THE SERVICE IS DOWN, spelled out because a test that
# passes having connected to nothing is worse than a red one (the CI "Fail if
# nothing was tested" gates exist for exactly this reason): every network call
# below is unguarded - no `|| true`, no `2>/dev/null || skip`. `set -euo
# pipefail` turns any curl failure, any non-200 status, any decode failure into
# an immediate nonzero exit. There is no code path in this script that reaches
# "PASS" without every one of PHASE_CHECKS below having actually run and
# succeeded against a live socket.
#
# Usage:
#   test/integration/bot-brain-live.sh
#
# Required environment:
#   BB_WIRE_TEST_BIN   path to the compiled bot_brain_wire_tests binary
#                       (built from modules/mod-bot-brain/t/bot_brain_wire_tests.cpp
#                       + modules/mod-bot-brain/src/BotBrainWire.cpp). No
#                       default: a missing binary is a FAIL, not a skip - the
#                       same rule modules/mod-bot-brain/t/bot_brain_wire_tests.cpp
#                       itself applies to its golden fixtures.
#
# Optional environment:
#   BB_SERVICE_DIR     services/bot-brain checkout (default: services/bot-brain,
#                       resolved from the repo root this script's path implies)
#   BB_PORT            loopback port to bind (default: 18085)

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"

: "${BB_SERVICE_DIR:=$repo_root/services/bot-brain}"
: "${BB_PORT:=18085}"

if [ -z "${BB_WIRE_TEST_BIN:-}" ]; then
    echo "FAIL bot-brain-live: BB_WIRE_TEST_BIN is not set." >&2
    echo "  This script proves the REAL C++ encoder/decoder against the REAL" >&2
    echo "  Go service; without the compiled binary there is nothing to prove," >&2
    echo "  so this is a failure, not a skip." >&2
    exit 1
fi
if [ ! -x "$BB_WIRE_TEST_BIN" ]; then
    echo "FAIL bot-brain-live: BB_WIRE_TEST_BIN=$BB_WIRE_TEST_BIN is not an executable file" >&2
    exit 1
fi
if [ ! -d "$BB_SERVICE_DIR" ]; then
    echo "FAIL bot-brain-live: no service checkout at $BB_SERVICE_DIR" >&2
    exit 1
fi

work="$(mktemp -d)"
service_bin="$work/bot-brain"
req_json="$work/request.json"
resp_json="$work/response.json"
resp_headers="$work/response.headers"
service_log="$work/service.log"
service_pid=""

PHASE_CHECKS=0
check() { PHASE_CHECKS=$((PHASE_CHECKS + 1)); echo "  check $PHASE_CHECKS: $*"; }

cleanup() {
    if [ -n "$service_pid" ] && kill -0 "$service_pid" 2>/dev/null; then
        kill "$service_pid" 2>/dev/null || true
        wait "$service_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

endpoint="http://127.0.0.1:$BB_PORT"

echo "== bot-brain-live: building the real service binary =="
( cd "$BB_SERVICE_DIR" && go build -o "$service_bin" ./cmd/bot-brain )
check "go build produced $service_bin"
[ -x "$service_bin" ]

echo "== bot-brain-live: starting the real service on $endpoint =="
# ADR-0012: the LLM stays off. BOT_BRAIN_LLM_ENABLED defaults to false in
# config.Load, but it is set here explicitly so this test fails loudly if that
# default is ever flipped, instead of quietly exercising a different code path.
BOT_BRAIN_LISTEN="127.0.0.1:$BB_PORT" \
BOT_BRAIN_LLM_ENABLED="false" \
    "$service_bin" >"$service_log" 2>&1 &
service_pid=$!

healthy=0
for _ in $(seq 1 50); do
    if curl -fsS "$endpoint/healthz" >/dev/null 2>&1; then
        healthy=1
        break
    fi
    if ! kill -0 "$service_pid" 2>/dev/null; then
        echo "FAIL bot-brain-live: service process exited before becoming healthy" >&2
        cat "$service_log" >&2
        exit 1
    fi
    sleep 0.2
done
if [ "$healthy" -ne 1 ]; then
    echo "FAIL bot-brain-live: /healthz never returned 200 within 10s" >&2
    cat "$service_log" >&2
    exit 1
fi
check "/healthz answered 200 on a live socket"

echo "== bot-brain-live: encoding a real plan request with the C++ encoder =="
"$BB_WIRE_TEST_BIN" --dump-request >"$req_json"
[ -s "$req_json" ]
check "bot_brain_wire_tests --dump-request produced a non-empty body"
grep -q '"contract_version"' "$req_json"
check "encoded request carries contract_version"

echo "== bot-brain-live: POSTing the C++-encoded request over the real socket =="
http_code=$(curl -sS -o "$resp_json" -D "$resp_headers" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    --data @"$req_json" "$endpoint/v1/plan")
check "curl completed the POST (no connection error)"
if [ "$http_code" != "200" ]; then
    echo "FAIL bot-brain-live: /v1/plan returned HTTP $http_code, wanted 200" >&2
    cat "$resp_json" >&2
    exit 1
fi
check "/v1/plan answered HTTP 200"

echo "== bot-brain-live: decoding the real response with the C++ decoder =="
decode_out="$work/decode.out"
if ! "$BB_WIRE_TEST_BIN" --check-response <"$resp_json" >"$decode_out"; then
    echo "FAIL bot-brain-live: the C++ decoder rejected a live response body" >&2
    cat "$decode_out" >&2
    exit 1
fi
cat "$decode_out"
grep -q '^DECODE_OK' "$decode_out"
check "C++ decoder accepted the live response (DECODE_OK)"
grep -q '^INTENT ' "$decode_out"
check "the batch of one snapshot came back with at least one decoded Intent"
grep -q 'bot_guid=4242' "$decode_out"
check "the Intent is addressed to the bot the request named (guid 4242)"

echo "PASS bot-brain-live: real Go service <-> real C++ wire code, $PHASE_CHECKS checks, over $endpoint"

# ---------------------------------------------------------------------------
# Issue #155's second criterion: the service dies, and the client degrades.
#
# There is no world here and no PlayerbotAI, so this cannot observe a bot
# keep questing. What it CAN prove, and does: the exact transport failure
# BotBrainClient.cpp's PostPlan wraps into HttpResult{ok=false} - a POST to a
# port nothing is listening on - actually happens (does not hang, does not
# return 200, does not return garbage that would decode as success), and that
# this script's own gate correctly turns it into a failure when a caller does
# not check for it. BotBrainPipeline.cpp:475-489 shows the consuming code:
# `if (exchange->result.ok) ... else the bot keeps the stock chooser`. This
# does not compile or run BotBrainClient.cpp itself (see README's caveat).
# ---------------------------------------------------------------------------
echo "== bot-brain-live: killing the service and re-driving the same request =="
kill "$service_pid"
wait "$service_pid" 2>/dev/null || true
service_pid=""

for _ in $(seq 1 25); do
    curl -fsS "$endpoint/healthz" >/dev/null 2>&1 || break
    sleep 0.2
done
if curl -fsS "$endpoint/healthz" >/dev/null 2>&1; then
    echo "FAIL bot-brain-live: /healthz still answers after the service was killed" >&2
    exit 1
fi
check "killed service no longer answers /healthz"

# The one assertion that makes the whole file honest: point the same live
# client-shaped request at the now-dead port and require the transport call
# itself to fail. If curl succeeded here, the "kill the service" test would
# have been proving nothing, silently, forever - which is the exact failure
# this script exists to rule out.
if curl -fsS -o "$resp_json" -X POST -H 'Content-Type: application/json' \
    --data @"$req_json" --max-time 5 "$endpoint/v1/plan" 2>/dev/null; then
    echo "FAIL bot-brain-live: /v1/plan answered successfully after the service was killed" >&2
    exit 1
fi
check "POST /v1/plan to the killed service fails closed (connection refused), not a hang or a 200"

echo "PASS bot-brain-live: killed service fails closed over the same socket, $PHASE_CHECKS total checks"
