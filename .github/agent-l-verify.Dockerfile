# syntax=docker/dockerfile:1.7
# TEMPORARY (Agent L). Verifies only the module targets touched by #139/#141.
#
# Two deviations from Dockerfile.core's `builder`, both forced by this runner:
#   - the build tree is /build inside the image, never a bind mount, because the
#     runner workspace is NFS and ld dies there with "final close failed: Stale
#     file handle" during cmake's own compiler check.
#   - parallelism is capped. The pod reports 20 CPUs but only ~9.2 GB available
#     memory, and `--parallel $(nproc)` OOM-kills buildkitd partway through.
ARG BASE
FROM ${BASE}
ARG JOBS=4
WORKDIR /src
COPY . /src
RUN --mount=type=cache,target=/ccache \
    CCACHE_DIR=/ccache cmake -S /src -B /build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/opt/turtle \
      -DTW_ARCH=x86-64-v2 \
      -DMODULES=static \
      -DBUILD_TESTING=ON \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
RUN --mount=type=cache,target=/ccache \
    CCACHE_DIR=/ccache cmake --build /build --parallel "${JOBS}" \
      --target mod_mod_dungeon_clear mod_mod_playerbots \
    && ctest --test-dir /build -R playerbot_legacy_event_write_guard --output-on-failure
