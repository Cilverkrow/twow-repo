#!/usr/bin/env bash
# Run one command inside the core build toolchain.
#
# WHY THIS EXISTS. ci.yml used to compile the tree twice on every push: once on
# the runner behind a warm ccache, and once inside `docker build` where the
# Dockerfile's ccache is a BuildKit cache mount and therefore not exported by
# type=gha. The second compile was 71 of the job's 77 minutes and started from
# zero every single time.
#
# The fix is to compile once, on the runner, and hand the finished install to
# the image. But the runner is Ubuntu 24.04 and the image is Debian trixie, and
# they disagree about the two libraries the server links hardest against: ACE
# (7.1.3 vs 8.0.2) and the MySQL client (libmysqlclient.so.21 vs libmariadb.so.3).
# A binary built on the runner installs into the image perfectly and then cannot
# exec. So the compile happens on the runner but *in a container* made from
# Dockerfile.core's `builder-base` stage - same Debian, same gcc, same sonames -
# with the ccache directory bind-mounted out to an ordinary path that
# actions/cache can carry between runs. That is the whole trick.
#
# The bind mounts, and why each one:
#   /src        the checkout, read-write but READ-ONLY IN PRACTICE for the
#               build: sources in, nothing of the build tree out. See below.
#   /build      the build tree, on a NAMED DOCKER VOLUME rather than under
#               /src. THIS IS LOAD-BEARING, do not "simplify" it back.
#
#               The build tree used to live at /src/build, inside the bind
#               mount, so that it survived between invocations of this script -
#               a container filesystem does not, and ccache keys on the compile
#               line, which includes paths. A named volume gives that same
#               survival, and fixes what the bind mount could not do.
#
#               On the self-hosted runner the /src bind mount is served over a
#               network filesystem. Reads and small writes work, which is why it
#               looks fine; `ld` does not. Every link died at its final close():
#
#                   /usr/bin/ld: cmTC_438e8: final close failed: Stale file handle
#
#               That is ESTALE, and it killed CMake's trivial "is the compiler
#               working" test before a single line of this project compiled. The
#               distinction that matters is that ld WRITES its output - sources
#               can stay on the network mount, outputs cannot. So only the build
#               tree moves, and it moves onto the docker daemon's own local disk.
#
#               A named volume behaves identically on a GitHub-hosted runner, so
#               this costs nothing there. It deliberately does NOT use a BuildKit
#               stage snapshot (`docker build --target builder`), which would put
#               the compile back inside `docker build` where the ccache is a
#               cache mount that type=gha cannot export - the exact arrangement
#               that cost 71 of this job's 77 minutes on every single push.
#   /ccache     the compiler cache, on the host so it can be saved and restored.
#               It stays a bind mount on purpose: actions/cache has to be able to
#               see it, and ccache's writes are ordinary small file writes that
#               the network mount handles. Only ld's pattern is the problem.
#   /opt/turtle the staging directory. CMAKE_INSTALL_PREFIX is baked into the
#               binary as SYSCONFDIR, so `cmake --install` must write to the
#               real prefix; mounting the host's ./stage there is how the files
#               come back out without a DESTDIR that would falsify the prefix.
#
# --network host because the MariaDB service container is published on the
# runner's 127.0.0.1:3306 and the adapter suite connects to it, and because
# FetchContent clones googletest during configure.
#
# --user the runner's own uid so everything written through the bind mounts is
# owned by the runner and the later upload/artifact steps can read it.
#
# Usage:
#   bash ops/ci/in-builder.sh 'cmake --build /src/build --parallel "$(nproc)"'
#
# Invoked through `bash` rather than by its executable bit for the same reason
# every other script here is: this repository is developed on Windows and
# carries no executable bits.

set -euo pipefail

: "${BUILDER_IMAGE:?BUILDER_IMAGE is not set - the toolchain image was never built}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Created here rather than in the workflow so that a step calling this script
# directly does not need to remember to.
mkdir -p "$REPO_ROOT/.ccache" "$REPO_ROOT/stage"

# The build tree's volume. Overridable so a second checkout on the same runner
# does not silently share one build tree with the first.
BUILD_VOLUME="${BUILD_VOLUME:-twow-build}"

# A named volume is created root-owned, and the build below runs as the runner's
# own uid so that everything it writes through the bind mounts stays readable by
# the later artefact steps. That uid cannot write into a fresh root-owned volume,
# so the first use of it fails with EACCES unless the ownership is fixed first.
#
# Done in a throwaway root container because the runner may not be root itself
# (it is on the self-hosted pod; it is not on a GitHub-hosted VM) and this has to
# work in both places. It is idempotent and costs one container start.
docker volume create "$BUILD_VOLUME" >/dev/null
docker run --rm --user 0:0 \
    --volume "$BUILD_VOLUME:/build" \
    "$BUILDER_IMAGE" \
    chown "$(id -u):$(id -g)" /build

# CCACHE_SLOPPINESS is not optional here. USE_PCH defaults to ON, and ccache
# refuses to cache a translation unit that includes a precompiled header unless
# pch_defines is allowed; the revision header also carries __DATE__/__TIME__,
# which is what time_macros is for. Without these the cache would report hits in
# the single digits and the 71 minutes would come straight back - which is why
# the build step prints `ccache --show-stats`.
#
# GIT_CONFIG_* below: the uid we run as is not in the image's /etc/passwd, and
# git refuses to read a repository it thinks belongs to somebody else. The
# revision header is generated by asking git for HEAD, so this is not optional.
exec docker run --rm \
    --network host \
    --user "$(id -u):$(id -g)" \
    --env HOME=/tmp \
    --env CCACHE_DIR=/ccache \
    --env CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-4G}" \
    --env CCACHE_COMPRESS=1 \
    --env CCACHE_COMPRESSLEVEL=1 \
    --env CCACHE_SLOPPINESS=pch_defines,time_macros,include_file_mtime,include_file_ctime \
    --env GIT_CONFIG_COUNT=1 \
    --env GIT_CONFIG_KEY_0=safe.directory \
    --env GIT_CONFIG_VALUE_0='*' \
    --volume "$REPO_ROOT:/src" \
    --volume "$BUILD_VOLUME:/build" \
    --volume "$REPO_ROOT/.ccache:/ccache" \
    --volume "$REPO_ROOT/stage:/opt/turtle" \
    --workdir /src \
    "$BUILDER_IMAGE" \
    bash -c "$*"
