#!/usr/bin/env bash
# Move the debug information of every installed ELF file out of the install
# prefix (#486 B4, owner decision 2b: split debug, never in the runtime layer).
#
# Usage:
#   bash deploy/docker/split-debug.sh <install-prefix> <debug-dir>
#
# Called from exactly two places, and both must keep calling it the same way,
# because this step is part of what makes the CI image and the published image
# the same build:
#   * Dockerfile.core, builder stage, after `cmake --install` (publish, nightly);
#   * ci.yml, build-and-test, "Stage the verified install" (the ci-staged image).
#
# For every regular ELF file below <install-prefix> (an absolute path):
#   1. objcopy --only-keep-debug   -> <debug-dir><absolute path>.debug, e.g.
#                                  <debug-dir>/opt/turtle/bin/mangosd.debug
#   2. strip --strip-debug         the installed file keeps its code and its
#                                  symbol table (.symtab), so a backtrace still
#                                  names functions; only DWARF leaves
#   3. objcopy --add-gnu-debuglink the installed file records the debug file's
#                                  name and CRC
#
# The layout mirrors the absolute install path because that is where gdb looks
# for a debuglink under a debug-file-directory (<dir>/<binary's dir>/<name>).
# With the debug-symbols artifact unpacked to ./dbg and a core dump of the
# image's /opt/turtle/bin/mangosd:
#   gdb -iex 'set debug-file-directory ./dbg' /path/to/mangosd core
# where /path/to/mangosd is the binary copied out of the SAME image (the
# build id and the debuglink CRC must match; gdb says so if they do not).
#
# <debug-dir>/BUILD-IDS lists "<gnu build-id>  <relative path>" per file. The
# build id is what ties a debug file to one exact binary; a debug file from a
# different build of the same commit does not match it.
#
# <debug-dir> must lie outside <install-prefix>: the runtime stage copies the
# whole prefix, and debug files in there would put the ~1 GB back into the
# image this exists to shrink.
#
# Runs inside the builder toolchain (binutils comes with build-essential).
# Invoked through `bash`, like every other script in this repository, because
# the tree carries no executable bits.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <install-prefix> <debug-dir>" >&2
    exit 2
fi

prefix=${1%/}
debug_dir=${2%/}

case "$prefix" in
    /?*) ;;
    *) echo "ERROR: install prefix must be an absolute path, got '$prefix'" >&2; exit 2 ;;
esac
if [ ! -d "$prefix" ]; then
    echo "ERROR: install prefix $prefix does not exist" >&2
    exit 2
fi
case "$debug_dir/" in
    "$prefix"/*)
        echo "ERROR: debug dir $debug_dir is inside the install prefix $prefix" >&2
        exit 2
        ;;
esac

for tool in objcopy strip readelf; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: $tool not found - run this inside the builder toolchain" >&2
        exit 2
    }
done

mkdir -p "$debug_dir"
manifest="$debug_dir/BUILD-IDS"
: > "$manifest"

is_elf() {
    [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ]
}

count=0
while IFS= read -r -d '' file; do
    is_elf "$file" || continue
    rel=${file#"$prefix"/}
    debug_file="$debug_dir$prefix/$rel.debug"
    mkdir -p "$(dirname "$debug_file")"

    objcopy --only-keep-debug --compress-debug-sections=zlib "$file" "$debug_file"
    strip --strip-debug "$file"
    objcopy --add-gnu-debuglink="$debug_file" "$file"

    if readelf -S --wide "$file" | grep -q ' \.debug_info '; then
        echo "ERROR: $rel still carries .debug_info after strip" >&2
        exit 1
    fi
    if ! readelf -S --wide "$file" | grep -q ' \.gnu_debuglink '; then
        echo "ERROR: $rel has no .gnu_debuglink after objcopy" >&2
        exit 1
    fi

    build_id=$(readelf -n "$file" | awk '/Build ID:/ { print $3; exit }')
    printf '%s  %s\n' "${build_id:-none}" "$rel" >> "$manifest"
    count=$((count + 1))
done < <(find "$prefix" -type f -print0 | LC_ALL=C sort -z)

if [ "$count" -eq 0 ]; then
    echo "ERROR: no ELF file found below $prefix - nothing was split" >&2
    exit 1
fi

echo "split-debug: $count ELF file(s) stripped, debug info in $debug_dir"
cat "$manifest"
