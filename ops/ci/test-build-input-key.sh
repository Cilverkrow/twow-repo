#!/usr/bin/env bash
# Offline contract for ops/ci/build-input-key.sh (#486 B5a): throwaway git
# repositories, no network, no container.
#
# The key must change with every build input (core gitlink, modules,
# deploy/docker, the root CMakeLists, .dockerignore, in-builder.sh, ci.yml)
# and must NOT change for anything else (docs, services, other workflows), and
# a commit missing an input must fail instead of yielding a key.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/ops/ci/build-input-key.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

g() { git -C "$WORK/repo" -c user.name=t -c user.email=t@example.invalid -c core.autocrlf=false "$@"; }
key() { bash "$SCRIPT" --repo "$WORK/repo" "${1:-HEAD}"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

CORE_A=1111111111111111111111111111111111111111
CORE_B=2222222222222222222222222222222222222222

git init -q "$WORK/repo"
mkdir -p "$WORK/repo/modules/mod-x" "$WORK/repo/deploy/docker" "$WORK/repo/deploy/compose" \
         "$WORK/repo/ops/ci" "$WORK/repo/.github/workflows" "$WORK/repo/docs"
echo 'project(x)'         > "$WORK/repo/CMakeLists.txt"
echo 'docs/'              > "$WORK/repo/.dockerignore"
echo 'int x;'             > "$WORK/repo/modules/mod-x/x.cpp"
echo 'FROM debian:trixie' > "$WORK/repo/deploy/docker/Dockerfile.core"
echo 'services: {}'       > "$WORK/repo/deploy/compose/docker-compose.yml"
echo 'echo build'         > "$WORK/repo/ops/ci/in-builder.sh"
echo 'name: ci'           > "$WORK/repo/.github/workflows/ci.yml"
echo 'name: nightly'      > "$WORK/repo/.github/workflows/nightly.yml"
echo '# doc'              > "$WORK/repo/docs/README.md"
mkdir -p "$WORK/repo/core"   # an empty directory keeps the gitlink staged through `add -A`
g add -A
g update-index --add --cacheinfo "160000,$CORE_A,core"
g commit -q -m base

base=$(key)
printf '%s' "$base" | grep -Eqx '[0-9a-f]{64}' || fail "key is not 64 hex: $base"
[ "$(key)" = "$base" ] || fail "key is not deterministic"
echo "key=deterministic"

# Unrelated changes keep the key.
same() {
    local name=$1
    g add -A
    g commit -q -m "$name"
    [ "$(key)" = "$base" ] || fail "$name changed the key"
    echo "$name=same_key"
}
echo '# more' >> "$WORK/repo/docs/README.md";                   same docs_change
echo 'name: nightly2' > "$WORK/repo/.github/workflows/nightly.yml"; same other_workflow
echo 'x: 1' >> "$WORK/repo/deploy/compose/docker-compose.yml";  same deploy_compose

# Every input changes it; each case is reverted afterwards so the cases are
# independent.
differs() {
    local name=$1 now
    g add -A
    g commit -q -m "$name"
    now=$(key)
    [ "$now" != "$base" ] || fail "$name did not change the key"
    g reset -q --hard HEAD~1
    [ "$(key)" = "$base" ] || fail "revert of $name did not restore the key"
    echo "$name=new_key"
}
echo 'int y;' >> "$WORK/repo/modules/mod-x/x.cpp";             differs modules
echo 'RUN true' >> "$WORK/repo/deploy/docker/Dockerfile.core"; differs deploy_docker
echo '# c' >> "$WORK/repo/CMakeLists.txt";                     differs root_cmakelists
echo 'ops/' >> "$WORK/repo/.dockerignore";                     differs dockerignore
echo '# j4' >> "$WORK/repo/ops/ci/in-builder.sh";              differs in_builder
echo '# flag' >> "$WORK/repo/.github/workflows/ci.yml";        differs ci_workflow
chmod +x "$WORK/repo/ops/ci/in-builder.sh"
g update-index --chmod=+x ops/ci/in-builder.sh
differs mode_change
g update-index --cacheinfo "160000,$CORE_B,core";              differs core_gitlink

# A missing input is an error, not a smaller key.
g rm -q --cached .dockerignore
g commit -q -m "drop dockerignore"
rc=0; key > "$WORK/missing.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "missing input: expected rc=1, got $rc"
grep -q '.dockerignore is missing' "$WORK/missing.log" || fail "missing input not named"
g reset -q --hard HEAD~1
echo "missing_input=rc1"

# core as a plain directory instead of a gitlink is an error.
g rm -q --cached core
mkdir -p "$WORK/repo/core"
echo x > "$WORK/repo/core/f"
g add core/f
g commit -q -m "core as tree"
rc=0; key > "$WORK/tree.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "core as a tree: expected rc=1, got $rc"
g reset -q --hard HEAD~1
echo "core_not_gitlink=rc1"

rc=0; key deadbeef > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "unknown revision: expected rc=1, got $rc"
echo "unknown_rev=rc1"

echo "build input key contract: ok"
