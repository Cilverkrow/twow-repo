#!/usr/bin/env bash
# Publish the client-derived dbc/ + maps/ payload that CI needs into a PRIVATE
# GHCR container package, so the smoke suite can start a real world server
# without a game client on the runner.
#
# WHY ONLY dbc + maps
# -------------------
# The smoke gate is have_client_data() in test/smoke/lib.sh, and it checks
# exactly two paths on the host side of the bind mount:
#
#     $DATA_PATH/maps   and   $DATA_PATH/dbc
#
# Nothing else. vmaps and mmaps buy line-of-sight and pathfinding, both of
# which mangosd treats as config-toggleable (vmap.* / mmap.enable in
# mangosd.conf), so the world server starts and the suite runs without them.
# They are also the expensive half: MoveMapGen alone is an hour or more of CPU,
# and the two directories together dwarf the payload below. This script
# therefore runs ONLY step 1 of deploy/compose/extract-client-data.sh
# (mapextractor -> dbc + maps) and deliberately does NOT run vmapextractor,
# vmap_assembler or MoveMapGen.
#
# MEASURED PAYLOAD (Turtle WoW 1.18.1 english client, build 7272)
# ---------------------------------------------------------------
#     dbc/     46,032,956 bytes (45 MiB)      158 files
#     maps/   153,916,480 bytes (147 MiB)   2,805 files
#     dbc/Spell.dbc          27,939,905 bytes  -- the single largest file
#     total   199,949,436 bytes over 2,963 files
#
# For contrast, from the same client: vmaps 292 MiB, mmaps 1.5 GiB. Skipping
# them is ~90% of the bytes and very nearly all of the wall clock.
#
# Three dbc files come out zero length -- CharacterCreateCameras.dbc,
# SpellAuraNames.dbc, SpellEffectNames.dbc. They are empty in the client
# itself; that is not a failed extraction.
#
# THE PACKAGE MUST STAY PRIVATE
# -----------------------------
# This payload is derived from a game client the operator owns. ADR-0023 keeps
# it out of Git permanently, and the same reasoning forbids publishing it where
# anyone can pull it. A fresh GHCR package under a user account defaults to
# private, but "defaults to" is not "is": the check below reads the package's
# visibility from the API and REFUSES TO PUSH unless it comes back private. A
# package that has never been pushed (404) is allowed through, because it will
# be created private; anything that is not literally "private", and any answer
# the script cannot read, aborts.
#
# The image is FROM scratch with nothing but the data. It is never executed --
# CI does `docker create` + `docker cp` to lift the directories out.
#
# Usage:
#     CLIENT_PATH=/path/to/client WORK_DIR=/path/to/scratch \
#     GHCR_TOKEN=... ops/assets/publish-client-data.sh
#
#     CLIENT_PATH  directory CONTAINING Data/ (the extractor exits 1 otherwise)
#     WORK_DIR     local scratch for extractor output. Never point this at a
#                  read-only share, and never at the repository.
#     DATA_PATH    extractor output, default $WORK_DIR/out
#     IMAGE        image name, default ghcr.io/cilverkrow/twow-client-data
#     VERSION_TAG  default 1.18.1
#     GHCR_TOKEN   token with read:packages, used only for the visibility
#                  check. `docker login ghcr.io` must already have succeeded.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)

CLIENT_PATH=${CLIENT_PATH:?set CLIENT_PATH to the client directory containing Data/}
WORK_DIR=${WORK_DIR:?set WORK_DIR to a local scratch directory}
IMAGE=${IMAGE:-ghcr.io/cilverkrow/twow-client-data}
VERSION_TAG=${VERSION_TAG:-1.18.1}
DATA_PATH=${DATA_PATH:-$WORK_DIR/out}

log() { printf '[publish-client-data] %s\n' "$*" >&2; }
die() { printf '[publish-client-data] ERROR: %s\n' "$*" >&2; exit 1; }

# ADR-0023 is a rule about where these bytes may live, so enforce it here
# rather than trusting the caller to pick a sane scratch directory.
case "$WORK_DIR" in
    "$REPO_ROOT" | "$REPO_ROOT"/*)
        die "WORK_DIR is inside the repository ($REPO_ROOT). Client-derived data never enters Git (ADR-0023)."
        ;;
esac

[ -d "$CLIENT_PATH/Data" ] ||
    die "no $CLIENT_PATH/Data -- CLIENT_PATH must be the unpacked client DIRECTORY, not the archive"

# ---------------------------------------------------------------- 1. extract
#
# Step 1 only. The compose service (`docker compose --profile tools run --rm
# extractor`) runs all three steps and cannot be told to stop after the first,
# so mapextractor is invoked directly in the same tools image. The commands
# below are exactly step 1 of deploy/compose/extract-client-data.sh: symlink
# the read-only client in, run mapextractor in a scratch directory, move the
# two result directories to the output.
mkdir -p "$DATA_PATH"
if [ -n "$(ls -A "$DATA_PATH/dbc" 2>/dev/null)" ] && [ -n "$(ls -A "$DATA_PATH/maps" 2>/dev/null)" ]; then
    log "dbc/ and maps/ already present in $DATA_PATH -- skipping extraction"
else
    log "building the extractor image (deploy/compose/Dockerfile.tools) ..."
    docker build -f "$REPO_ROOT/deploy/compose/Dockerfile.tools" -t twow-extractors:local "$REPO_ROOT"

    log "running mapextractor -- dbc + maps only, NOT vmaps, NOT mmaps ..."
    mkdir -p "$WORK_DIR/extract"
    docker run --rm \
        -v "$CLIENT_PATH:/client:ro" \
        -v "$DATA_PATH:/out" \
        -v "$WORK_DIR/extract:/work/extract" \
        --entrypoint /bin/bash twow-extractors:local -c '
            set -eu
            cd /work/extract
            ln -sfn /client/Data /work/extract/Data
            mapextractor
            for d in dbc maps; do rm -rf "/out/$d"; mv "/work/extract/$d" "/out/$d"; done
        '
fi

[ -d "$DATA_PATH/dbc" ] || die "no $DATA_PATH/dbc after extraction"
[ -d "$DATA_PATH/maps" ] || die "no $DATA_PATH/maps after extraction"

# ---------------------------------------------------------------- 2. measure
log "dbc/  $(du -sb "$DATA_PATH/dbc" | cut -f1) bytes, $(find "$DATA_PATH/dbc" -type f | wc -l) files"
log "maps/ $(du -sb "$DATA_PATH/maps" | cut -f1) bytes, $(find "$DATA_PATH/maps" -type f | wc -l) files"
log "Spell.dbc $(stat -c %s "$DATA_PATH/dbc/Spell.dbc") bytes"

# Content tag: sha256 over a sorted manifest of relative path + size. Same data
# in, same tag out, so re-running against unchanged output does not churn tags.
content_tag="sha-$( (cd "$DATA_PATH" && find dbc maps -type f -printf '%p %s\n' | LC_ALL=C sort) | sha256sum | cut -c1-12)"
log "content tag: $content_tag"

# --------------------------------------------------- 3. refuse a public package
#
# Checked BEFORE the push, not after: once the bytes are on a public package it
# is too late to be careful.
pkg=${IMAGE##*/}
[ -n "${GHCR_TOKEN:-}" ] ||
    die "GHCR_TOKEN is unset, so the package's visibility cannot be verified. Refusing to push blind."

response=$(curl -sS -w '\n%{http_code}' \
    -H "Authorization: token $GHCR_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user/packages/container/$pkg")
http_code=${response##*$'\n'}
case "$http_code" in
    404)
        log "package $pkg does not exist yet -- GHCR creates it private"
        ;;
    200)
        visibility=$(printf '%s' "${response%$'\n'*}" |
            tr ',' '\n' |
            sed -n 's/.*"visibility"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        [ "$visibility" = "private" ] ||
            die "package $pkg visibility is '$visibility', not 'private'. Refusing to push client-derived data to a non-private package (ADR-0023)."
        log "package $pkg is private"
        ;;
    *)
        die "could not read the visibility of package $pkg (HTTP $http_code). Refusing to push blind."
        ;;
esac

# ------------------------------------------------------- 4. build and push
#
# FROM scratch: the image is a container for bytes, never a runtime. vmaps and
# mmaps are excluded from the build context as well as from the image, because
# transferring 1.5 GiB that is then dropped is pure waste.
printf 'vmaps\nmmaps\nDockerfile\n.dockerignore\n' > "$DATA_PATH/.dockerignore"
cat > "$DATA_PATH/Dockerfile" <<'DOCKERFILE'
# syntax=docker/dockerfile:1.7
# Client-derived dbc/ + maps/ only. Never executed: CI does docker create + docker cp.
FROM scratch
COPY dbc /dbc
COPY maps /maps
# There is no binary in this image and nothing ever runs it, but `docker create`
# refuses an image with no command at all -- "no command specified" -- and
# `docker cp` needs a created container. A CMD that could never execute is
# enough to satisfy that, and costs nothing.
CMD ["/dbc"]
DOCKERFILE

docker build -t "$IMAGE:$VERSION_TAG" -t "$IMAGE:$content_tag" "$DATA_PATH"
docker push "$IMAGE:$VERSION_TAG"
docker push "$IMAGE:$content_tag"

log "pushed $IMAGE:$VERSION_TAG and $IMAGE:$content_tag"
log "consume with: docker create --name cd $IMAGE:$content_tag && docker cp cd:/dbc \"\$DATA_PATH/dbc\""
