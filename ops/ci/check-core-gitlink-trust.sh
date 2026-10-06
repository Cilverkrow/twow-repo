#!/usr/bin/env bash
# The core gitlink must point at a commit that is already on a trusted branch of
# twow-core: origin/main or an origin/release/* branch (#486, plan B1).
#
#   check-core-gitlink-trust.sh [--repo DIR] [--core-url URL] [--work DIR]
#                               [--compare LOCAL_FILE=CORE_PATH]
#
# WHY. A pin PR can set the `core` gitlink to any commit GitHub will serve from
# the twow-core network - including the head of a fork's pull request
# (refs/pull/N/head) that nobody reviewed or merged. CI would build and test it,
# and promote/publish would ship it. Requiring the commit to be an ancestor of a
# protected core branch ties what the platform builds to what passed core's own
# review and rulesets.
#
# The URL is NOT taken from .gitmodules: a PR could point the submodule at a fork
# whose `main` contains anything. .gitmodules must name the expected URL, and the
# fetch always goes to that expected URL.
#
#   --repo DIR       platform checkout to read HEAD:core and .gitmodules from
#                    (default: repository root above this script)
#   --core-url URL   expected and fetched core URL
#                    (default: https://github.com/Cilverkrow/twow-core.git)
#   --work DIR       empty or absent directory for the commit-only clone
#                    (default: a temporary directory, removed on exit)
#   --compare L=C    after the trust check, require the file C in the pinned core
#                    commit to be byte-identical to the local file L. Skipped with
#                    a notice when C does not exist in that commit.
#
# Needs only git and network access to the public core repository; no token.
# The clone is commit-only (--filter=tree:0), so the fetch is small.

set -euo pipefail

ROOT_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="$ROOT_DEFAULT"
CORE_URL="https://github.com/Cilverkrow/twow-core.git"
WORK=""
COMPARE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?}"; shift ;;
        --core-url) CORE_URL="${2:?}"; shift ;;
        --work) WORK="${2:?}"; shift ;;
        --compare) COMPARE="${2:?}"; shift ;;
        -h|--help) sed -n '4,5p' "$0" | sed 's/^# *//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

fail() { echo "::error::core-gitlink-trust: $*"; exit 1; }

gitlink="$(git -C "$REPO" ls-tree HEAD core | awk '$2 == "commit" { print $3 }')"
[ -n "$gitlink" ] || fail "HEAD has no 'core' gitlink"
[[ "$gitlink" =~ ^[0-9a-f]{40}$ ]] || fail "gitlink '$gitlink' is not a 40-hex commit id"

# The committed .gitmodules, not the working tree's.
declared="$(git -C "$REPO" config --blob HEAD:.gitmodules --get submodule.core.url 2>/dev/null || true)"
[ "$declared" = "$CORE_URL" ] \
    || fail ".gitmodules names core url '$declared', expected '$CORE_URL'"

if [ -z "$WORK" ]; then
    WORK="$(mktemp -d)"
    # Cleanup must never decide the result (#515): a late write into the directory
    # makes rm fail with "Directory not empty", and under set -e that would turn a
    # passed check into a failed step. The verdict comes from fail() alone.
    trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
fi
mkdir -p "$WORK"

git init -q --bare "$WORK"
# No background gc or maintenance in the throwaway clone (#515): git can start one
# after a fetch (including the lazy fetches of --compare) and keep writing into
# $WORK while the exit trap removes it. Set in the repo config, which the lazy
# fetches read too, and again on every call by G.
git -C "$WORK" config gc.auto 0
git -C "$WORK" config maintenance.auto false
G() { git -c gc.auto=0 -c maintenance.auto=false -C "$WORK" "$@"; }
G remote add origin "$CORE_URL"
# A refspec that matches no branch (no release/* yet) is not an error.
G -c protocol.version=2 fetch -q --no-tags --filter=tree:0 origin \
    '+refs/heads/main:refs/remotes/origin/main' \
    '+refs/heads/release/*:refs/remotes/origin/release/*' \
    || fail "cannot fetch main and release/* from $CORE_URL"

echo "core gitlink : $gitlink"
echo "core url     : $CORE_URL"
echo "trusted refs :"
G for-each-ref --format='  %(refname:short) %(objectname)' \
    refs/remotes/origin/main 'refs/remotes/origin/release/*'

trusted=""
if G cat-file -e "${gitlink}^{commit}" 2>/dev/null; then
    while IFS= read -r ref; do
        if G merge-base --is-ancestor "$gitlink" "$ref"; then
            trusted="$ref"
            break
        fi
    done < <(G for-each-ref --format='%(refname:short)' \
                 refs/remotes/origin/main 'refs/remotes/origin/release/*')
fi

[ -n "$trusted" ] || fail "gitlink $gitlink is not contained in core main or any release/* branch - merge it in twow-core first"
echo "trusted      : $gitlink is contained in $trusted"

if [ -n "$COMPARE" ]; then
    local_file="${COMPARE%%=*}"
    core_path="${COMPARE#*=}"
    [ -f "$local_file" ] || fail "--compare: local file $local_file missing"
    # tree:0 is a partial clone: trees and the blob are fetched on demand here.
    if ! G cat-file -e "$gitlink:$core_path" 2>/dev/null; then
        echo "::notice::core $gitlink has no $core_path - comparison skipped"
    else
        core_sha="$(G cat-file blob "$gitlink:$core_path" | sha256sum | cut -d' ' -f1)"
        local_sha="$(sha256sum < "$local_file" | cut -d' ' -f1)"
        [ "$core_sha" = "$local_sha" ] \
            || fail "core copy $core_path ($core_sha) differs from $local_file ($local_sha)"
        echo "identical    : $local_file = core:$core_path ($local_sha)"
    fi
fi
