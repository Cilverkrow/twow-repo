#!/usr/bin/env bash
# Publish the client-derived dbc/ + maps/ + vmaps/ + mmaps/ payload that CI
# needs into a PRIVATE GHCR container package, so the smoke suite can start a
# real world server without a game client on the runner.
#
# WHY ALL FOUR DIRECTORIES
# ------------------------
# have_client_data() in test/smoke/lib.sh only checks two paths on the host
# side of the bind mount -- $DATA_PATH/maps and $DATA_PATH/dbc -- so an
# earlier revision of this script shipped just those two. That was wrong.
#
# config/canonical/compose/mangosd.overlay.conf does not set vmap.enableLOS,
# vmap.enableHeight or mmap.enabled, so all three inherit the base template's
# value of 1. The server we actually ship therefore starts up EXPECTING
# line-of-sight and pathfinding data. Shipping a payload without vmaps and
# mmaps would mean either
#
#   * a CI-only override that disables them, i.e. a config divergence between
#     what CI exercises and what production runs -- the one thing the smoke
#     gate exists to prevent; or
#   * bots that cannot path, which is precisely the behaviour the bot brain
#     drives and therefore precisely what the suite needs to observe.
#
# It is also load-bearing for known bugs: issue #218 was an mmap-related
# assert, and the evidence capture on #155 explicitly records that it ran with
# vmaps and mmaps present in order to avoid it. Reproducing either without the
# pathfinding data is not reproducing them.
#
# The cost is real but it is a ONE-TIME cost. Generating vmaps and mmaps takes
# hours of CPU (MoveMapGen dominates), but once $DATA_PATH holds them this
# script reuses them; the extraction block below is skipped for every directory
# that is already populated. Publishing is then only an upload.
#
# MEASURED PAYLOAD (Turtle WoW 1.18.1 english client, build 7272)
# ---------------------------------------------------------------
#     dbc/        46,032,956 bytes (44 MiB)      158 files
#     maps/      153,916,480 bytes (147 MiB)   2,805 files
#     vmaps/     293,604,215 bytes (280 MiB)   4,521 files
#     mmaps/   1,583,191,064 bytes (1.47 GiB)  1,435 files
#     total    2,076,744,715 bytes (1.93 GiB)  8,919 files
#
#     dbc/Spell.dbc  27,939,905 bytes -- the single largest file
#
# Compressed, that pushes as roughly 812 MiB of layers.
#
# WHAT THE PATHFINDING DATA COVERS
# --------------------------------
# Not every map. The generated set is:
#
#     vmaps   6 .vmtree (maps 0, 1, 26, 27, 28, 30), 1,144 .vmtile,
#             3,371 .vmo model files. The trees for 26 and 28 are 101 bytes,
#             i.e. structurally valid but empty.
#     mmaps   2 .mmap (maps 0 and 1 only) and 1,433 .mmtile, split
#             597 / 836 between the two.
#
# Maps 0 and 1 are Eastern Kingdoms and Kalimdor, which is where the bots run.
# mangosd treats a missing per-map tree or mmap as "no vmap/mmap for this map"
# and continues; it does not refuse to start. So partial coverage is safe, but
# it is partial -- do not read a green smoke run on map 0 as evidence that
# pathfinding works in an instance.
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
#     VERSION_TAG  default 1.18.1-full. The plain 1.18.1 tag is the older
#                  dbc+maps-only payload and is deliberately left in place for
#                  callers that knowingly want the smaller download.
#     GHCR_TOKEN   token with read:packages, used only for the visibility
#                  check. `docker login ghcr.io` must already have succeeded.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)

CLIENT_PATH=${CLIENT_PATH:?set CLIENT_PATH to the client directory containing Data/}
WORK_DIR=${WORK_DIR:?set WORK_DIR to a local scratch directory}
IMAGE=${IMAGE:-ghcr.io/cilverkrow/twow-client-data}
VERSION_TAG=${VERSION_TAG:-1.18.1-full}
DATA_PATH=${DATA_PATH:-$WORK_DIR/out}

PAYLOAD_DIRS="dbc maps vmaps mmaps"

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
# All four directories, which is what deploy/compose/extract-client-data.sh
# does. This is the hours-long part: mapextractor is minutes, vmapextractor +
# vmap_assembler is tens of minutes, MoveMapGen is hours. Every directory that
# already exists and is non-empty is left alone, so an interrupted run resumes
# at the first missing one and a fully-populated $DATA_PATH costs nothing.
mkdir -p "$DATA_PATH"

missing=""
for d in $PAYLOAD_DIRS; do
    [ -n "$(ls -A "$DATA_PATH/$d" 2>/dev/null)" ] || missing="$missing $d"
done

if [ -z "$missing" ]; then
    log "all of $PAYLOAD_DIRS already present in $DATA_PATH -- skipping extraction"
else
    log "missing:$missing -- running the extractor (this takes HOURS; MoveMapGen dominates)"
    log "building the extractor image (deploy/compose/Dockerfile.tools) ..."
    docker build -f "$REPO_ROOT/deploy/compose/Dockerfile.tools" -t twow-extractors:local "$REPO_ROOT"

    mkdir -p "$WORK_DIR/extract"
    docker run --rm \
        -v "$CLIENT_PATH:/client:ro" \
        -v "$DATA_PATH:/out" \
        -v "$WORK_DIR/extract:/work/extract" \
        -e MISSING="$missing" \
        --entrypoint /bin/bash twow-extractors:local -c '
            set -eu
            cd /work/extract
            ln -sfn /client/Data /work/extract/Data

            case " $MISSING " in
                *" dbc "* | *" maps "*)
                    mapextractor
                    for d in dbc maps; do rm -rf "/out/$d"; mv "/work/extract/$d" "/out/$d"; done
                    ;;
            esac

            case " $MISSING " in
                *" vmaps "*)
                    vmapextractor
                    mkdir -p /work/extract/vmaps
                    vmap_assembler /work/extract/Buildings /work/extract/vmaps
                    rm -rf /out/vmaps
                    mv /work/extract/vmaps /out/vmaps
                    ;;
            esac

            case " $MISSING " in
                *" mmaps "*)
                    # MoveMapGen reads maps/, vmaps/ and dbc/. Point it at the
                    # copies already in /out rather than re-deriving them.
                    for d in maps vmaps dbc; do
                        [ -e "/work/extract/$d" ] || ln -sfn "/out/$d" "/work/extract/$d"
                    done
                    mkdir -p /work/extract/mmaps
                    MoveMapGen
                    rm -rf /out/mmaps
                    mv /work/extract/mmaps /out/mmaps
                    ;;
            esac
        '
fi

for d in $PAYLOAD_DIRS; do
    [ -n "$(ls -A "$DATA_PATH/$d" 2>/dev/null)" ] || die "no $DATA_PATH/$d after extraction"
done

# ---------------------------------------------------------------- 2. measure
total=0
for d in $PAYLOAD_DIRS; do
    bytes=$(du -sb "$DATA_PATH/$d" | cut -f1)
    total=$((total + bytes))
    log "$(printf '%-6s' "$d/") $bytes bytes, $(find "$DATA_PATH/$d" -type f | wc -l) files"
done
log "total  $total bytes"
log "Spell.dbc $(stat -c %s "$DATA_PATH/dbc/Spell.dbc") bytes"
log "vmaps  $(find "$DATA_PATH/vmaps" -name '*.vmtree' | wc -l) map trees, $(find "$DATA_PATH/vmaps" -name '*.vmtile' | wc -l) tiles"
log "mmaps  $(find "$DATA_PATH/mmaps" -name '*.mmap' | wc -l) maps, $(find "$DATA_PATH/mmaps" -name '*.mmtile' | wc -l) tiles"

# Content tag: sha256 over a sorted manifest of relative path + size. Same data
# in, same tag out, so re-running against unchanged output does not churn tags.
content_tag="sha-$( (cd "$DATA_PATH" && find $PAYLOAD_DIRS -type f -printf '%p %s\n' | LC_ALL=C sort) | sha256sum | cut -c1-12)"
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
# FROM scratch: the image is a container for bytes, never a runtime. One COPY
# per directory, so a change confined to one of them re-pushes one layer
# instead of all four.
printf 'Dockerfile\n.dockerignore\n' > "$DATA_PATH/.dockerignore"
cat > "$DATA_PATH/Dockerfile" <<'DOCKERFILE'
# syntax=docker/dockerfile:1.7
# Client-derived dbc/ + maps/ + vmaps/ + mmaps/. Never executed:
# CI does docker create + docker cp to lift the directories out.
FROM scratch
COPY dbc /dbc
COPY maps /maps
COPY vmaps /vmaps
COPY mmaps /mmaps
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
log "consume with:"
log "  docker create --name cd $IMAGE:$content_tag"
log "  for d in $PAYLOAD_DIRS; do docker cp \"cd:/\$d\" \"\$DATA_PATH/\$d\"; done"
log "  docker rm -f cd"
