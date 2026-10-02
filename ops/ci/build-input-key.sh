#!/usr/bin/env bash
# The build-input key of a platform commit (#486 B5a): one sha256 over
# everything that decides what the core image contains.
#
#   build-input-key.sh [--repo DIR] [REV]      (REV defaults to HEAD)
#
# Two commits with the same key compile to the same image, so a commit whose CI
# skipped the C++ build can be given the image already promoted for an earlier
# commit with the same key, without compiling (promote.yml). ci.yml labels every
# image it assembles with the key (io.twow.build-input) and promote.yml pushes a
# `bi-<key>` tag next to `sha-<40>` so the image can be found again; the label,
# not the tag, is what a reuse trusts.
#
# Inputs, as `git ls-tree` entries (mode, type, object id, path) of REV:
#   core                       the gitlink: the whole core tree
#   CMakeLists.txt             the platform root that configures it
#   .dockerignore              what `COPY . /src` sends (publish's from-source path)
#   modules                    the platform modules linked into mangosd
#   deploy/docker              Dockerfile.core, entrypoints, split-debug.sh
#   ops/ci/in-builder.sh       how ci.yml runs the compile in builder-base
#   .github/workflows/ci.yml   the configure flags of the build that is promoted
#
# Deliberately conservative: any change to these, a comment in ci.yml included,
# is a new key and therefore a new build. Not covered, and cannot be: the
# moving debian:trixie base and apt packages. A reused image keeps the base it
# was built on, exactly as if that commit had been deployed.
#
# Fails (exit 1) when an input is missing at REV - a key over fewer inputs
# would match commits it must not match. Needs only git.

set -euo pipefail

REPO="."
REV="HEAD"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?--repo needs a directory}"; shift ;;
        -h|--help) sed -n '5p' "$0" | sed 's/^# *//'; exit 0 ;;
        -*) echo "unknown argument: $1" >&2; exit 2 ;;
        *) REV="$1" ;;
    esac
    shift
done

INPUTS=(core CMakeLists.txt .dockerignore modules deploy/docker ops/ci/in-builder.sh .github/workflows/ci.yml)

git -C "$REPO" rev-parse --verify --quiet "$REV^{commit}" >/dev/null \
    || { echo "build-input-key: $REV is not a commit in $REPO" >&2; exit 1; }

listing=$(git -C "$REPO" ls-tree "$REV" -- "${INPUTS[@]}")

for path in "${INPUTS[@]}"; do
    printf '%s\n' "$listing" | awk -F '\t' -v p="$path" '$2 == p { found = 1 } END { exit !found }' \
        || { echo "build-input-key: $path is missing at $REV" >&2; exit 1; }
done
printf '%s\n' "$listing" | awk '$2 == "commit" && $NF == "core" { found = 1 } END { exit !found }' \
    || { echo "build-input-key: core is not a gitlink at $REV" >&2; exit 1; }

# The version line makes a future change of the input list a new key space
# instead of a silent collision with keys computed under the old list.
{ echo "twow-build-input-v1"; printf '%s\n' "$listing" | LC_ALL=C sort -t "$(printf '\t')" -k2; } \
    | sha256sum | cut -d' ' -f1
