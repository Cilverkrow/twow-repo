#!/usr/bin/env bash
# Compile every core header on its own and report the ones that do not build.
#
# A header that uses a type without declaring it compiles fine for as long as
# every translation unit reaching it happens to include the declaration first.
# The day one does not, the errors are reported against a header that file never
# touched. Four of these landed in a single afternoon -- Conditions.h,
# SharedDefines.h, LFTMgr.h and WorldSession.h -- each one found by a Windows CI
# job twelve minutes at a time, because GCC's include order in this tree happens
# to be luckier than MSVC's.
#
# So: check them all at once, and fail only on a header that is not already
# known to be broken. The baseline is not an approval of the ones in it -- it is
# a ratchet, so the number can go down and not up.
#
# Usage:
#   ops/audit/header-self-containment.sh <build-dir> [--update-baseline]
#
# The build directory must have been configured with
# -DCMAKE_EXPORT_COMPILE_COMMANDS=ON: the flags come from the real compile line
# for a src/game translation unit, so this checks what the build checks.

set -euo pipefail

BUILD_DIR="${1:?usage: $0 <build-dir> [--update-baseline]}"
MODE="${2:-check}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASELINE="$REPO_ROOT/ops/audit/header-self-containment-baseline.txt"
CC_JSON="$BUILD_DIR/compile_commands.json"

if [ ! -f "$CC_JSON" ]; then
    echo "no $CC_JSON - configure with -DCMAKE_EXPORT_COMPILE_COMMANDS=ON" >&2
    exit 2
fi

# Flags from a real src/game compile line, minus the parts naming the input and
# the output. -w because we are looking for errors, not style.
COMPILE_LINE="$(python3 "$REPO_ROOT/ops/audit/extract_compile_flags.py" "$CC_JSON")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failed="$TMP/failed.txt"
: > "$failed"
: > "$TMP/detail.txt"
total=0

while IFS= read -r header; do
    total=$((total + 1))
    rel="${header#"$REPO_ROOT/"}"
    printf '#include "%s"\n' "$header" > "$TMP/probe.cpp"
    if ! eval "$COMPILE_LINE -fsyntax-only -w \"$TMP/probe.cpp\"" > "$TMP/err.txt" 2>&1; then
        echo "$rel" >> "$failed"
        {
            echo "### $rel"
            grep -m3 -E "error:" "$TMP/err.txt" || true
        } >> "$TMP/detail.txt"
    fi
done < <(find "$REPO_ROOT/src/game" -name '*.h' | sort)

sort -o "$failed" "$failed"

if [ "$MODE" = "--update-baseline" ]; then
    cp "$failed" "$BASELINE"
    echo "baseline updated: $(wc -l < "$BASELINE") of $total headers"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "no baseline at $BASELINE" >&2
    exit 2
fi

# New offenders only. A header LEAVING the baseline is good news and must not
# fail the build, so this compares in one direction.
new="$(comm -13 "$BASELINE" "$failed" || true)"
gone="$(comm -23 "$BASELINE" "$failed" || true)"

echo "checked $total headers; $(wc -l < "$failed") not self-contained, baseline $(wc -l < "$BASELINE")"

if [ -n "$gone" ]; then
    echo "fixed since the baseline (re-run with --update-baseline to record):"
    echo "$gone" | sed 's/^/  - /'
fi

if [ -n "$new" ]; then
    echo "$new" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        echo "::error file=$f::header is not self-contained; include what it uses"
        awk -v want="### $f" 'BEGIN{p=0} $0==want{p=1;next} /^### /{p=0} p' "$TMP/detail.txt" | sed 's/^/    /'
    done
    exit 1
fi

echo "no new offenders"
