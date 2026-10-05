#!/usr/bin/env bash
# Tests for deploy/docker/split-debug.sh (#486 B4, owner decision 2b).
#
# Argument guards always run. The real split runs only where a C compiler and
# binutils exist (the GitHub-hosted lint runner has both; the Windows host's
# Git Bash has neither): compile a tiny program with -g1, install it into a
# fake prefix next to a non-ELF file, split, and check that the installed
# binary lost its DWARF but kept a debuglink, the .debug file landed at the
# mirrored install path outside the prefix, and the binary still runs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/deploy/docker/split-debug.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

expect_rc() {
    local want=$1 name=$2 rc=0
    shift 2
    bash "$SCRIPT" "$@" > "$WORK/$name.log" 2>&1 || rc=$?
    if [ "$rc" -ne "$want" ]; then
        echo "FAIL: $name - expected rc=$want, got rc=$rc" >&2
        cat "$WORK/$name.log" >&2
        exit 1
    fi
    echo "$name=rc$want"
}

mkdir -p "$WORK/prefix/bin"
expect_rc 2 no_arguments
expect_rc 2 relative_prefix prefix "$WORK/dbg"
expect_rc 2 missing_prefix "$WORK/nope" "$WORK/dbg"
expect_rc 2 debug_inside_prefix "$WORK/prefix" "$WORK/prefix/debug"

for tool in cc objcopy strip readelf; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "real_split=skipped ($tool not available here; runs in the CI lint job)"
        exit 0
    fi
done

prefix="$WORK/opt/turtle"
mkdir -p "$prefix/bin" "$prefix/etc"
printf 'int main(void) { return 0; }\n' > "$WORK/main.c"
cc -O2 -g1 -o "$prefix/bin/mangosd" "$WORK/main.c"
printf 'Key = 1\n' > "$prefix/etc/mangosd.conf.dist"
readelf -S --wide "$prefix/bin/mangosd" | grep -q ' \.debug_info ' || {
    echo "FAIL: the -g1 fixture has no .debug_info to split" >&2
    exit 1
}

expect_rc 0 real_split "$prefix" "$WORK/dbg"

debug_file="$WORK/dbg$prefix/bin/mangosd.debug"
[ -f "$debug_file" ] || { echo "FAIL: $debug_file missing" >&2; exit 1; }
readelf -S --wide "$debug_file" | grep -q ' \.debug_info ' || {
    echo "FAIL: the .debug file carries no .debug_info" >&2
    exit 1
}
if readelf -S --wide "$prefix/bin/mangosd" | grep -q ' \.debug_info '; then
    echo "FAIL: the installed binary still carries .debug_info" >&2
    exit 1
fi
readelf -S --wide "$prefix/bin/mangosd" | grep -q ' \.gnu_debuglink ' || {
    echo "FAIL: the installed binary has no .gnu_debuglink" >&2
    exit 1
}
readelf -S --wide "$prefix/bin/mangosd" | grep -q ' \.symtab ' || {
    echo "FAIL: --strip-debug removed .symtab; backtraces would lose names" >&2
    exit 1
}
"$prefix/bin/mangosd" || { echo "FAIL: the stripped binary no longer runs" >&2; exit 1; }
grep -Eq '  bin/mangosd$' "$WORK/dbg/BUILD-IDS" || {
    echo "FAIL: BUILD-IDS does not list bin/mangosd" >&2
    exit 1
}
if grep -q 'mangosd.conf.dist' "$WORK/dbg/BUILD-IDS"; then
    echo "FAIL: a non-ELF file was treated as ELF" >&2
    exit 1
fi
if find "$prefix" -name '*.debug' | grep -q .; then
    echo "FAIL: a .debug file was left inside the install prefix" >&2
    exit 1
fi
echo 'real_split=verified'
