#!/usr/bin/env bash
# Repository-only test: renders with synthetic credentials into a temporary
# directory, verifies it, proves drift detection, and removes the directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d)
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

export CONFIG_OUT_DIR="$TMP/config"
export DB_USER=synthetic-user
export DB_PASSWORD=synthetic-password
export WORLD_PORT=18090
export REALM_PORT=13724
export AIPLAYERBOT_MIN_BOTS=3
export AIPLAYERBOT_MAX_BOTS=7

if test -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)"; then
    unset ALLOW_DIRTY_CONFIG_SOURCE
    if bash "$ROOT/deploy/compose/render-config.sh" >/dev/null 2>&1; then
        echo "ERROR: renderer accepted a dirty source checkout by default" >&2
        exit 1
    fi
    export ALLOW_DIRTY_CONFIG_SOURCE=1
fi

bash "$ROOT/deploy/compose/render-config.sh" >/dev/null
bash "$ROOT/deploy/compose/verify-config.sh" >/dev/null

grep -Fq synthetic-password "$CONFIG_OUT_DIR/mangosd.conf"
grep -Eq '^WorldServerPort[[:space:]]*=[[:space:]]*8090$' "$CONFIG_OUT_DIR/mangosd.conf"
grep -Eq '^RealmServerPort[[:space:]]*=[[:space:]]*3724$' "$CONFIG_OUT_DIR/realmd.conf"
if grep -Fq synthetic-password "$CONFIG_OUT_DIR/config-provenance.txt" || \
   grep -Fq synthetic-user "$CONFIG_OUT_DIR/config-provenance.txt"; then
    echo "ERROR: provenance contains a credential" >&2
    exit 1
fi

printf '\n# deliberate test drift\n' >> "$CONFIG_OUT_DIR/mangosd.conf"
if bash "$ROOT/deploy/compose/verify-config.sh" >/dev/null 2>&1; then
    echo "ERROR: verifier accepted a changed rendered file" >&2
    exit 1
fi

bash "$ROOT/deploy/compose/render-config.sh" >/dev/null
bash "$ROOT/deploy/compose/verify-config.sh" >/dev/null
echo "config provenance test passed"
