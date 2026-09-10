#!/usr/bin/env bash
# Server-free test of the actual resolver; no bootstrap entry point is sourced.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
log() { printf '%s\n' "$*" >&2; }
# Only the resolver definitions are loaded; sourcing the full bootstrap is unsafe.
# shellcheck source=/dev/null
source <(sed -n '/^reconcile_stream() {$/,/^}$/p; /^reconcile_empty_logon_stream() {$/,/^}$/p' "$root/deploy/compose/db-init.sh")
mkdir "$scratch/platform" "$scratch/core"
printf 'SELECT 1;\n' > "$scratch/platform/20260101_world.sql"
printf 'SELECT 1;\r\n' > "$scratch/core/20260101_world.sql"
printf 'SELECT 2;\n' > "$scratch/core/20260102_world.sql"
reconcile_stream "$scratch/result" "$scratch/platform" "$scratch/core"
test "$(wc -l < "$scratch/result")" = 2
test "$(head -1 "$scratch/result")" = "$scratch/platform/20260101_world.sql"
test "$(tail -1 "$scratch/result")" = "$scratch/core/20260102_world.sql"
echo 'ORDER_DEDUP_CRLF_IDENTITY=PASS'
printf 'SELECT 3;\n' > "$scratch/core/20260101_world.sql"
if reconcile_stream "$scratch/result" "$scratch/platform" "$scratch/core"; then
    echo 'Content conflict was accepted' >&2; exit 1
fi
echo 'CONTENT_CONFLICT_REJECTED=PASS'
if reconcile_stream "$scratch/result" "$scratch/missing"; then
    echo 'Missing directory was accepted' >&2; exit 1
fi
echo 'MISSING_DIRECTORY_REJECTED=PASS'
reconcile_empty_logon_stream "$scratch/logon-result" "$scratch/no-platform-logon" "$scratch/no-core-logon"
test ! -s "$scratch/logon-result"
echo 'ABSENT_EMPTY_CORE_LOGON_STREAM=PASS'
mkdir "$scratch/present-logon"
if reconcile_empty_logon_stream "$scratch/logon-result" "$scratch/present-logon" "$scratch/no-core-logon"; then
    echo 'Partial declared logon stream was accepted' >&2; exit 1
fi
echo 'PARTIAL_DECLARED_LOGON_STREAM_REJECTED=PASS'
