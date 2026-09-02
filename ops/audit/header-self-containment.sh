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
# STALE AS OF THE core/ SPLIT (ADR-0020). The baseline's seven entries were
# re-rooted under core/ so the comparison lines up at all, but they were
# measured against THIS repository's old copy of src/game. The core is
# twow-core's now and is 386 upstream commits further on, with 148 more headers
# and its own history of self-containment fixes. Expect this audit to report new
# offenders on its first run against the submodule, and settle them with one
# deliberate `--update-baseline` rather than by editing the list by hand.
#
# Usage:
#   bash ops/audit/header-self-containment.sh <build-dir> [--update-baseline]
#
# Invoked through `bash` on purpose. This repository is developed on Windows and
# carries no executable bits -- db-init.sh and render-config.sh are called the
# same way -- so relying on one would break the moment a Windows commit dropped
# it. It already did once: the first CI run of this step failed with
# "Permission denied".
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

# One probe per header, run in parallel.
#
# 216 headers compiled one after another was four minutes of the build job, and
# the only reason it was serial is that a single probe.cpp and a single append
# to the failure list cannot survive concurrency: two workers would overwrite
# each other's probe and interleave each other's lines. So every worker writes
# its own files, named after a hash of the header path, and the results are
# collated afterwards in `find | sort` order. The report is therefore identical
# whatever order the compilers happen to finish in - same baseline comparison,
# same ::error annotations, same exit codes.
# CI_BUILD_JOBS overrides nproc. Every probe is a -fsyntax-only compile of a
# game header: cheap in time and NOT cheap in resident memory, so on the shared
# CI pod (~9.2 GiB free, 20 cores visible) one probe per core is the same memory
# demand as the full build. The workflow passes the same cap it gives ninja;
# nproc stays the default for anyone running this by hand.
jobs="${CI_BUILD_JOBS:-$(nproc 2>/dev/null || echo 4)}"

headers="$TMP/headers.txt"
# core/src/game, not src/game: the core is the core/ submodule now (ADR-0020)
# and this repository has no src/ of its own. The audit still belongs here
# rather than in twow-core because it is driven off THIS build's
# compile_commands.json - the flags a header has to be self-contained under are
# the platform's flags, modules included, not a standalone core's.
find "$REPO_ROOT/core/src/game" -name '*.h' | sort > "$headers"
total=$(wc -l < "$headers")
mkdir -p "$TMP/probes"

# A file rather than a shell function: xargs starts a fresh shell per probe, and
# `export -f` is a bashism that would tie this to whatever /bin/sh happens to be.
cat > "$TMP/probe.sh" <<'PROBE'
set -uo pipefail
header="$1"
rel="${header#"$REPO_ROOT/"}"
id="$(printf '%s' "$rel" | md5sum | cut -d' ' -f1)"
src="$TMP/probes/$id.cpp"
err="$TMP/probes/$id.err"
printf '#include "%s"\n' "$header" > "$src"
if ! eval "$COMPILE_LINE -fsyntax-only -w \"$src\"" > "$err" 2>&1; then
    {
        echo "### $rel"
        grep -m3 -E "error:" "$err" || true
    } > "$TMP/probes/$id.detail"
    echo "$rel" > "$TMP/probes/$id.failed"
fi
# Always zero. A header that does not compile is this script's finding, not a
# failure of the probe, and a non-zero worker makes xargs give up early.
exit 0
PROBE

export COMPILE_LINE REPO_ROOT TMP

# -d '\n' rather than the default whitespace split: a header path containing a
# space would otherwise arrive at the probe as two separate arguments.
xargs -a "$headers" -d '\n' -P "$jobs" -I{} bash "$TMP/probe.sh" {}

while IFS= read -r header; do
    rel="${header#"$REPO_ROOT/"}"
    id="$(printf '%s' "$rel" | md5sum | cut -d' ' -f1)"
    [ -f "$TMP/probes/$id.failed" ] || continue
    cat "$TMP/probes/$id.failed" >> "$failed"
    cat "$TMP/probes/$id.detail" >> "$TMP/detail.txt"
done < "$headers"

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
