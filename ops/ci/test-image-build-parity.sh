#!/usr/bin/env bash
# Container-free contract: the image ci.yml assembles and the image publish.yml
# builds are the same build (#486 B3/B4), and the debug information stays out
# of the runtime image (owner decision 2b).
#
# Promotion (#486 B5) ships the CI image instead of rebuilding it. That is only
# honest while both pipelines configure the shipped targets identically, split
# the debug info identically, and label the image the same way. This test reads
# the files and fails on drift; it builds nothing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="$ROOT/deploy/docker/Dockerfile.core"
CI="$ROOT/.github/workflows/ci.yml"
PUBLISH="$ROOT/.github/workflows/publish.yml"
PARITY="$ROOT/.github/workflows/image-parity.yml"
DOCKERIGNORE="$ROOT/.dockerignore"

failures=0
fail() {
    echo "ERROR: $*" >&2
    failures=$((failures + 1))
}

# Lines from the stage `FROM ... AS <name>` up to the next FROM.
stage() {
    awk -v name="$1" '
        /^FROM / { inside = ($NF == name) }
        inside { print }
    ' "$DOCKERFILE"
}

# -DKEY=VALUE pairs of a cmake configure, one per line, sorted.
cmake_defs() {
    grep -oE -- '-D[A-Za-z_]+=[^ \\'"'"']+' | sed 's/^-D//' | LC_ALL=C sort -u
}

# ------------------------------------------------------------ configure parity
builder=$(stage builder)
[ -n "$builder" ] || fail "Dockerfile.core has no builder stage"

arg_default() {
    # ARG <name>=<default> in the builder stage, else at the top of the file.
    local value
    value=$(printf '%s\n' "$builder" | sed -n "s/^ARG $1=//p" | head -1)
    [ -n "$value" ] || value=$(sed -n "s/^ARG $1=//p" "$DOCKERFILE" | head -1)
    printf '%s' "$value"
}

docker_defs=$(printf '%s\n' "$builder" \
    | sed -n '/cmake -S \/src -B \/build/,/COMPILER_LAUNCHER=ccache$/p' \
    | cmake_defs)
for arg in BUILD_TYPE PREFIX TW_ARCH MODULES; do
    docker_defs=$(printf '%s\n' "$docker_defs" | sed "s|\${$arg}|$(arg_default "$arg")|")
done

# build-and-test's configure, the one run in the builder toolchain (the MSVC
# job has a Configure step of its own and is not part of this contract).
ci_configure=$(sed -n "/in-builder.sh 'cmake -S \/src -B \/build -G Ninja/,/COMPILER_LAUNCHER=ccache'\$/p" "$CI")
[ -n "$ci_configure" ] || fail "ci.yml has no in-builder cmake configure"
ci_debug=$(sed -n "s/^      CI_CACHE_DEBUG_SYMBOLS: '\(.*\)'$/\1/p" "$CI")
[ -n "$ci_debug" ] || fail "ci.yml does not set CI_CACHE_DEBUG_SYMBOLS"
ci_defs=$(printf '%s\n' "$ci_configure" \
    | sed "s|\${{ env.CI_CACHE_DEBUG_SYMBOLS }}|$ci_debug|" \
    | cmake_defs)

# What ships is decided by these; they must be present and equal in both.
for key in CMAKE_BUILD_TYPE CMAKE_INSTALL_PREFIX TW_ARCH MODULES \
           DEBUG_SYMBOLS CMAKE_C_FLAGS CMAKE_CXX_FLAGS \
           CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER; do
    d=$(printf '%s\n' "$docker_defs" | sed -n "s/^$key=//p")
    c=$(printf '%s\n' "$ci_defs" | sed -n "s/^$key=//p")
    [ -n "$d" ] || fail "Dockerfile builder configure does not set $key"
    [ -n "$c" ] || fail "ci.yml Configure does not set $key"
    [ "$d" = "$c" ] || fail "$key differs: Dockerfile=$d ci.yml=$c"
done

# The expected values themselves (note 3/4 in Dockerfile.core).
expected='CMAKE_BUILD_TYPE=Release
CMAKE_INSTALL_PREFIX=/opt/turtle
TW_ARCH=x86-64-v2
MODULES=static
DEBUG_SYMBOLS=OFF
CMAKE_C_FLAGS=-g1
CMAKE_CXX_FLAGS=-g1'
while IFS= read -r pair; do
    printf '%s\n' "$docker_defs" | grep -Fqx -- "$pair" || fail "Dockerfile builder configure lacks $pair"
done <<< "$expected"

# The Dockerfile may set nothing CI does not; CI may add only test switches,
# which add test targets without install() rules (note 3 in Dockerfile.core).
while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    printf '%s\n' "$ci_defs" | grep -Fqx -- "$pair" || fail "Dockerfile sets $pair, ci.yml does not"
done <<< "$docker_defs"
while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    printf '%s\n' "$docker_defs" | grep -Fqx -- "$pair" && continue
    case "$pair" in
        BUILD_TESTING=ON|BUILD_PERSISTENT_ROSTER_ADAPTER_TESTS=ON|CMAKE_EXPORT_COMPILE_COMMANDS=ON) ;;
        *) fail "ci.yml sets $pair, Dockerfile.core does not (only test switches may differ)" ;;
    esac
done <<< "$ci_defs"

# publish/nightly must not override the builder's defaults with build-args.
for wf in "$PUBLISH" "$ROOT/.github/workflows/nightly.yml"; do
    if grep -Eq '^ +(TW_ARCH|MODULES|PREFIX)=' "$wf"; then
        fail "$(basename "$wf") overrides a builder ARG that the parity depends on"
    fi
    if grep -Eq '^ +BUILD_TYPE=' "$wf" && grep -E '^ +BUILD_TYPE=' "$wf" | grep -vq 'BUILD_TYPE=Release$'; then
        fail "$(basename "$wf") builds a BUILD_TYPE other than Release"
    fi
done

# ------------------------------------------------------------- split debug info
printf '%s\n' "$builder" | grep -Fq 'bash /src/deploy/docker/split-debug.sh "${PREFIX}" /debug-symbols' \
    || fail "Dockerfile builder stage does not run split-debug.sh after the install"
grep -Fq 'bash deploy/docker/split-debug.sh /opt/turtle /src/debug-symbols' "$CI" \
    || fail "ci.yml does not run split-debug.sh on the staged install"
grep -Eq '^FROM scratch AS debug-symbols$' "$DOCKERFILE" \
    || fail "Dockerfile.core has no FROM-scratch debug-symbols stage"
stage debug-symbols | grep -Fqx 'COPY --from=builder /debug-symbols /' \
    || fail "debug-symbols stage does not copy /debug-symbols from the builder"
for s in runtime-base runtime ci-staged; do
    if stage "$s" | grep -v '^#' | grep -q 'debug-symbols'; then
        fail "stage $s references the debug symbols - they must never be in a runtime layer"
    fi
done
stage runtime | grep -Fqx 'COPY --from=builder ${PREFIX} ${PREFIX}' \
    || fail "runtime stage no longer copies exactly \${PREFIX} from the builder"
grep -Fqx 'debug-symbols/' "$DOCKERIGNORE" || fail ".dockerignore does not exclude debug-symbols/"
if grep -Eq '^/?stage/?$' "$DOCKERIGNORE"; then
    fail ".dockerignore excludes ./stage, which ci-staged COPYs"
fi
grep -Fq 'name: debug-symbols' "$CI" || fail "ci.yml does not upload the debug-symbols artifact"

# ------------------------------------------------------------------- labels
for label in \
    'org.opencontainers.image.revision=${{ github.sha }}' \
    'org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}' \
    'org.opencontainers.image.version=sha-${{ github.sha }}' \
    'io.twow.core.revision=${{ steps.core-revision.outputs.sha }}'; do
    grep -Fqx "            $label" "$CI" || fail "ci-staged image lacks label $label"
done
grep -Fqx '            io.twow.core.revision=${{ steps.core-revision.outputs.sha }}' "$PUBLISH" \
    || fail "publish.yml does not label io.twow.core.revision"

# ------------------------------------------------------------------ publish B3
if grep -v '^ *#' "$PUBLISH" | grep -Eq 'type=gha.*scope=core'; then
    fail "publish.yml still reads or writes the dead type=gha core cache"
fi
grep -Fq 'type=gha,mode=max,scope=db-init' "$PUBLISH" \
    || fail "publish.yml lost the db-init cache (only the core cache was meant to go)"
digest_step=$(sed -n '/- name: Record the published digest/,/- name: Upload publish-digest.json/p' "$PUBLISH")
[ -n "$digest_step" ] || fail "publish.yml has no 'Record the published digest' step"
for key in repo_sha core_sha image digest workflow run_id built_at; do
    printf '%s\n' "$digest_step" | grep -Eq -- "--arg $key " \
        && printf '%s\n' "$digest_step" | grep -Fq "$key: \$$key" \
        || fail "publish-digest.json does not carry $key"
done
grep -Fq 'name: publish-digest' "$PUBLISH" || fail "publish.yml does not upload publish-digest.json"
# Same checkout depth as ci.yml's build-and-test, so the two builds see the
# same .git (revision.h is depth-independent, but the context should not be).
if grep -v '^ *#' "$PUBLISH" | grep -Eq 'fetch-depth: *0'; then
    fail "publish.yml checks out full history; ci.yml builds from fetch-depth 1"
fi
grep -Fq 'target: debug-symbols' "$PUBLISH" || fail "publish.yml does not export the debug-symbols stage"
if grep -B3 -A12 'target: debug-symbols' "$PUBLISH" | grep -q 'push: true'; then
    fail "publish.yml pushes the debug-symbols stage - it must stay an artifact"
fi

# --------------------------------------------------------- image-parity.yml
if [ ! -f "$PARITY" ]; then
    fail "image-parity.yml is missing"
else
    on_block=$(sed -n '/^on:/,/^[a-z]/p' "$PARITY")
    printf '%s\n' "$on_block" | grep -q '^  workflow_dispatch:' \
        || fail "image-parity.yml is not workflow_dispatch"
    if printf '%s\n' "$on_block" | grep -Eq '^  (push|pull_request|pull_request_target|schedule|workflow_run|issue_comment):'; then
        fail "image-parity.yml must be workflow_dispatch only"
    fi
    perms=$(sed -n '/^permissions:/,/^[a-z]/p' "$PARITY" | grep -E '^  [a-z-]+:' | LC_ALL=C sort)
    [ "$perms" = "$(printf '  actions: read\n  contents: read')" ] \
        || fail "image-parity.yml top-level permissions must be exactly contents: read, actions: read"
    if grep -v '^ *#' "$PARITY" | grep -Eq '^ +[a-z-]+: write'; then
        fail "image-parity.yml grants a write permission"
    fi
    runs_on=$(grep -E '^ +runs-on:' "$PARITY" | sed 's/^ *runs-on: *//' | LC_ALL=C sort -u)
    [ "$runs_on" = 'ubuntu-latest' ] || fail "image-parity.yml runs-on must be the literal ubuntu-latest"
fi

if [ "$failures" -ne 0 ]; then
    echo "image build parity contract: $failures failure(s)" >&2
    exit 1
fi
printf '%s\n' 'configure_parity=ok' 'split_debug=outside_runtime_image' \
    'labels=ci_and_publish' 'publish_gha_core_cache=removed' \
    'image_parity_workflow=dispatch_read_only'
