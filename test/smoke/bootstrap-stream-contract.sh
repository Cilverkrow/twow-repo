#!/usr/bin/env bash
# Server-free test of the actual resolver; no bootstrap entry point is sourced.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
log() { printf '%s\n' "$*" >&2; }
# Only the resolver definition is loaded; sourcing the full bootstrap is unsafe.
# shellcheck source=/dev/null
source <(sed -n '/^reconcile_stream() {$/,/^}$/p' "$root/deploy/compose/db-init.sh")
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
