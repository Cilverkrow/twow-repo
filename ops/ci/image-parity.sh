#!/usr/bin/env bash
# Compare two extracted /opt/turtle trees - the one in the image ci.yml
# assembled (ci-staged) and the one in the image publish.yml pushed (runtime) -
# for one commit (#486 B4). Used by .github/workflows/image-parity.yml; tested
# without containers by ops/ci/test-image-parity.sh.
#
# Usage:
#   bash ops/ci/image-parity.sh <core-sha> <ci-tree> <published-tree> <out-dir>
#
# Fails (exit 1) when any of these differ:
#   * the file list: relative path, type and permission bits of every entry;
#   * the compiled-in revision (the core's generated revision.h, which never
#     ships as a file): REVISION_HASH is the first 20 hex digits of the core
#     commit and must be in bin/mangosd of both trees (realmd includes
#     revision.h but prints only _FULLVERSION, i.e. REVISION_DATE, so the
#     hash is not in that binary); REVISION_DATE (`YYYY-MM-DD HH:MM:SS +ZZZZ`)
#     must be present and the same set in bin/mangosd and bin/realmd of both;
#   * the content of every non-ELF file (configs, Lua extensions);
#   * the debug state of every ELF file, when readelf is available: whether it
#     still carries .debug_info and whether it has a .gnu_debuglink. After B4
#     both trees must be stripped with a debuglink.
# ELF contents are NOT compared byte for byte: the two images are compiled by
# two different builds, and __DATE__/__TIME__ alone make the bytes differ.
# Their sizes are reported for information.
#
# Writes <out-dir>/report.md plus the raw lists it compared.

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <core-sha> <ci-tree> <published-tree> <out-dir>" >&2
    exit 2
fi

core_sha=$1
ci_tree=${2%/}
pub_tree=${3%/}
out=${4%/}

printf '%s' "$core_sha" | grep -Eqx '[0-9a-f]{40}' || {
    echo "ERROR: core sha must be 40 lowercase hex digits" >&2
    exit 2
}
for tree in "$ci_tree" "$pub_tree"; do
    [ -d "$tree" ] || { echo "ERROR: $tree is not a directory" >&2; exit 2; }
done
mkdir -p "$out"

rev_hash=${core_sha:0:20}
date_re='[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [+-][0-9]{4}'
report="$out/report.md"
failures=0

fail() {
    failures=$((failures + 1))
    printf -- '- FAIL: %s\n' "$*" >> "$report"
}
pass() {
    printf -- '- ok: %s\n' "$*" >> "$report"
}

is_elf() {
    [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]
}

# path<TAB>type<TAB>mode, sorted, for every entry below the tree root.
list_tree() {
    (cd "$1" && find . -mindepth 1 -printf '%P\t%y\t%m\n' | LC_ALL=C sort)
}

{
    echo '# Image parity: CI image vs published image'
    echo
    echo "- core commit: \`$core_sha\` (REVISION_HASH \`$rev_hash\`)"
    echo
    echo '## File list (path, type, mode)'
    echo
} > "$report"

list_tree "$ci_tree" > "$out/ci-files.txt"
list_tree "$pub_tree" > "$out/published-files.txt"
if diff -u "$out/ci-files.txt" "$out/published-files.txt" > "$out/files.diff"; then
    pass "$(wc -l < "$out/ci-files.txt" | tr -d ' ') entries, identical"
else
    fail "file lists differ (see files.diff)"
    { echo; echo '```diff'; cat "$out/files.diff"; echo '```'; } >> "$report"
fi

{ echo; echo '## Compiled-in revision (revision.h)'; echo; } >> "$report"
for bin in bin/mangosd bin/realmd; do
    for side in ci published; do
        if [ "$side" = ci ]; then tree=$ci_tree; else tree=$pub_tree; fi
        if [ ! -f "$tree/$bin" ]; then
            fail "$side: $bin is missing"
            continue
        fi
        if [ "$bin" = bin/mangosd ]; then
            if grep -aqF "$rev_hash" "$tree/$bin"; then
                pass "$side: $bin carries REVISION_HASH $rev_hash"
            else
                fail "$side: $bin does not carry REVISION_HASH $rev_hash"
            fi
        fi
        grep -aoE "$date_re" "$tree/$bin" | LC_ALL=C sort -u \
            > "$out/$side-$(basename "$bin")-revision-date.txt" || true
    done
    name=$(basename "$bin")
    if [ -f "$out/ci-$name-revision-date.txt" ] \
       && [ -f "$out/published-$name-revision-date.txt" ]; then
        if [ ! -s "$out/ci-$name-revision-date.txt" ]; then
            fail "$name: no REVISION_DATE found"
        elif cmp -s "$out/ci-$name-revision-date.txt" "$out/published-$name-revision-date.txt"; then
            pass "$name: REVISION_DATE identical ($(tr '\n' ' ' < "$out/ci-$name-revision-date.txt" | sed 's/ $//'))"
        else
            fail "$name: REVISION_DATE differs: ci=[$(tr '\n' ' ' < "$out/ci-$name-revision-date.txt")] published=[$(tr '\n' ' ' < "$out/published-$name-revision-date.txt")]"
        fi
    fi
done

{ echo; echo '## File contents and debug state'; echo; } >> "$report"
have_readelf=no
command -v readelf >/dev/null 2>&1 && have_readelf=yes
[ "$have_readelf" = yes ] || echo '- note: readelf not available, ELF debug state not checked' >> "$report"

debug_state() {
    local sections info=no link=no
    sections=$(readelf -S --wide "$1" 2>/dev/null || true)
    printf '%s\n' "$sections" | grep -q ' \.debug_info ' && info=yes
    printf '%s\n' "$sections" | grep -q ' \.gnu_debuglink ' && link=yes
    printf 'debug_info=%s debuglink=%s' "$info" "$link"
}

while IFS=$'\t' read -r path type _; do
    [ "$type" = f ] || continue
    [ -f "$pub_tree/$path" ] || continue
    ci_file="$ci_tree/$path"
    pub_file="$pub_tree/$path"
    if is_elf "$ci_file" || is_elf "$pub_file"; then
        ci_size=$(stat -c %s "$ci_file")
        pub_size=$(stat -c %s "$pub_file")
        if [ "$have_readelf" = yes ]; then
            ci_state=$(debug_state "$ci_file")
            pub_state=$(debug_state "$pub_file")
            if [ "$ci_state" != "$pub_state" ]; then
                fail "$path: debug state differs: ci($ci_state) published($pub_state)"
            elif [ "$ci_state" != 'debug_info=no debuglink=yes' ]; then
                fail "$path: not split (both $ci_state)"
            else
                pass "$path: ELF, split in both ($ci_state); size ci=$ci_size published=$pub_size"
            fi
        else
            pass "$path: ELF; size ci=$ci_size published=$pub_size"
        fi
    elif cmp -s "$ci_file" "$pub_file"; then
        pass "$path: identical"
    else
        fail "$path: content differs"
    fi
done < "$out/ci-files.txt"

{
    echo
    if [ "$failures" -eq 0 ]; then
        echo '**Result: PARITY** - same file list, same revision, same non-ELF content.'
    else
        echo "**Result: MISMATCH** - $failures check(s) failed."
    fi
} >> "$report"

cat "$report"
[ "$failures" -eq 0 ]
