#!/usr/bin/env bash
# Container-free tests for ops/ci/image-parity.sh (#486 B4).
#
# The fixtures are not ELF files, so this runs the same everywhere (Git Bash on
# the Windows host has no readelf): it covers the file list, the compiled-in
# revision and the non-ELF content comparison. The ELF debug-state branch runs
# for real in .github/workflows/image-parity.yml.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/ops/ci/image-parity.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

CORE=441d62e771be7269d5803051df11b565b03e7ff6
REV=${CORE:0:20}
DATE='2026-10-02 19:13:36 +0200'

make_tree() {
    local dir=$1 rev=$2 date=$3
    mkdir -p "$dir/bin/lua_scripts/extensions" "$dir/etc/modules" "$dir/run"
    printf 'x\0%s\0%s\0y' "$rev" "$date" > "$dir/bin/mangosd"
    # realmd prints only REVISION_DATE, never the hash - like the real binary.
    printf 'x\0%s\0y' "$date" > "$dir/bin/realmd"
    printf '#!/bin/sh\n' > "$dir/bin/run-mangosd"
    printf 'Key = 1\n' > "$dir/etc/mangosd.conf.dist"
    printf 'Key = 2\n' > "$dir/etc/modules/mod_leech.conf.dist"
    printf -- '-- lua\n' > "$dir/bin/lua_scripts/extensions/_Misc.ext"
}

expect() {
    local name=$1 want=$2
    shift 2
    local rc=0
    bash "$SCRIPT" "$@" > "$WORK/$name.log" 2>&1 || rc=$?
    if [ "$want" = pass ] && [ "$rc" -ne 0 ]; then
        echo "FAIL: $name - expected parity, got rc=$rc" >&2
        cat "$WORK/$name.log" >&2
        exit 1
    fi
    if [ "$want" = fail ] && [ "$rc" -ne 1 ]; then
        echo "FAIL: $name - expected a mismatch (rc=1), got rc=$rc" >&2
        cat "$WORK/$name.log" >&2
        exit 1
    fi
    echo "$name=$want"
}

# 1. identical trees
make_tree "$WORK/ci" "$REV" "$DATE"
make_tree "$WORK/pub" "$REV" "$DATE"
expect identical pass "$CORE" "$WORK/ci" "$WORK/pub" "$WORK/out-identical"
grep -q 'Result: PARITY' "$WORK/out-identical/report.md"

# 2. an extra file in the published tree (e.g. a test binary that got installed)
make_tree "$WORK/ci2" "$REV" "$DATE"
make_tree "$WORK/pub2" "$REV" "$DATE"
printf 'test\n' > "$WORK/pub2/bin/mangosd_cli_input_tests"
expect extra_file fail "$CORE" "$WORK/ci2" "$WORK/pub2" "$WORK/out-extra"
grep -q 'mangosd_cli_input_tests' "$WORK/out-extra/files.diff"

# 3. a different core revision compiled into the published binaries
make_tree "$WORK/ci3" "$REV" "$DATE"
make_tree "$WORK/pub3" "0000000000000000000a" "$DATE"
expect other_revision fail "$CORE" "$WORK/ci3" "$WORK/pub3" "$WORK/out-rev"
grep -q 'published: bin/mangosd does not carry REVISION_HASH' "$WORK/out-rev/report.md"

# 4. same hash, different revision date (a rebuilt or amended core commit)
make_tree "$WORK/ci4" "$REV" "$DATE"
make_tree "$WORK/pub4" "$REV" '2026-10-02 17:13:36 +0000'
expect other_date fail "$CORE" "$WORK/ci4" "$WORK/pub4" "$WORK/out-date"
grep -q 'REVISION_DATE differs' "$WORK/out-date/report.md"

# 5. a config file with different content
make_tree "$WORK/ci5" "$REV" "$DATE"
make_tree "$WORK/pub5" "$REV" "$DATE"
printf 'Key = 3\n' > "$WORK/pub5/etc/mangosd.conf.dist"
expect config_content fail "$CORE" "$WORK/ci5" "$WORK/pub5" "$WORK/out-conf"
grep -q 'etc/mangosd.conf.dist: content differs' "$WORK/out-conf/report.md"

# 6. same path, different type (directory vs file)
make_tree "$WORK/ci6" "$REV" "$DATE"
make_tree "$WORK/pub6" "$REV" "$DATE"
rm -r "$WORK/pub6/run"
printf 'x\n' > "$WORK/pub6/run"
expect entry_type fail "$CORE" "$WORK/ci6" "$WORK/pub6" "$WORK/out-type"

# 7. a missing binary
make_tree "$WORK/ci7" "$REV" "$DATE"
make_tree "$WORK/pub7" "$REV" "$DATE"
rm "$WORK/pub7/bin/realmd"
expect missing_binary fail "$CORE" "$WORK/ci7" "$WORK/pub7" "$WORK/out-missing"
grep -q 'published: bin/realmd is missing' "$WORK/out-missing/report.md"

# 8. argument validation
rc=0
bash "$SCRIPT" not-a-sha "$WORK/ci" "$WORK/pub" "$WORK/out-bad" > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: a malformed core sha must exit 2, got $rc" >&2; exit 1; }
echo 'bad_core_sha=rejected'
