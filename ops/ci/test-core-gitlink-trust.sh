#!/usr/bin/env bash
# Offline contract test for ops/ci/check-core-gitlink-trust.sh (#486).
#
# Builds a throwaway core repository with main, release/8.x, an unmerged feature
# branch and a PR-only commit (refs/pull/1/head), plus a platform repository whose
# `core` gitlink is moved between them. No network, no submodule checkout.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/ops/ci/check-core-gitlink-trust.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

g() { git -c user.name=ci -c user.email=ci@example.invalid -c init.defaultBranch=main \
          -c commit.gpgsign=false -c core.autocrlf=false "$@"; }

core="$TMP/core"
g init -q "$core"
mkdir -p "$core/.github/policy"
echo policy-v1 > "$core/.github/policy/copy.sh"
g -C "$core" add .
g -C "$core" commit -q -m base
main1="$(g -C "$core" rev-parse HEAD)"
g -C "$core" checkout -q -b release/8.x
g -C "$core" commit -q --allow-empty -m hotfix
rel1="$(g -C "$core" rev-parse HEAD)"
g -C "$core" checkout -q -b feature/x main
g -C "$core" commit -q --allow-empty -m unmerged
feat1="$(g -C "$core" rev-parse HEAD)"
g -C "$core" checkout -q main
g -C "$core" commit -q --allow-empty -m pr-head
pr1="$(g -C "$core" rev-parse HEAD)"
g -C "$core" update-ref refs/pull/1/head "$pr1"
g -C "$core" reset -q --hard "$main1"
g -C "$core" commit -q --allow-empty -m main-tip
url="file://$core"

plat="$TMP/platform"
g init -q "$plat"

pin() { # pin <commit> <url in .gitmodules>
    printf '[submodule "core"]\n\tpath = core\n\turl = %s\n' "$2" > "$plat/.gitmodules"
    g -C "$plat" add .gitmodules
    g -C "$plat" update-index --add --cacheinfo "160000,$1,core"
    g -C "$plat" commit -q --allow-empty -m "pin $1"
}

pass=0
expect() { # expect <ok|fail> <pattern in output> <label> <args...>
    local want="$1" pattern="$2" label="$3" rc=0 out
    shift 3
    out="$(bash "$CHECK" --repo "$plat" --core-url "$url" "$@" 2>&1)" || rc=$?
    if { { [ "$want" = ok ] && [ "$rc" -eq 0 ]; } || { [ "$want" = fail ] && [ "$rc" -ne 0 ]; }; } \
       && grep -Fq -- "$pattern" <<< "$out"; then
        echo "ok   : $label ($want)"
        pass=$((pass + 1))
    else
        echo "FAIL : $label expected $want, rc=$rc"
        printf '%s\n' "$out" | sed 's/^/    /'
        exit 1
    fi
}

pin "$main1" "$url";  expect ok   "contained in origin/main" "gitlink on core main"
pin "$rel1" "$url";   expect ok   "contained in origin/release/8.x" "gitlink on core release/8.x"
pin "$feat1" "$url";  expect fail "is not contained in core main" "gitlink on an unmerged feature branch"
pin "$pr1" "$url";    expect fail "is not contained in core main" "gitlink only reachable from refs/pull/1/head"
pin "$main1" "https://github.com/someone/twow-core.git"
expect fail "expected" ".gitmodules points at another repository"

pin "$main1" "$url"
echo policy-v1 > "$TMP/same.sh"
echo policy-v2 > "$TMP/other.sh"
expect ok   "identical    :" "core copy identical" --compare "$TMP/same.sh=.github/policy/copy.sh"
expect fail "differs from" "core copy differs" --compare "$TMP/other.sh=.github/policy/copy.sh"
expect ok   "comparison skipped" "core copy absent (skip)" --compare "$TMP/same.sh=.github/policy/missing.sh"

echo "core gitlink trust contract: $pass case(s) passed"
