#!/usr/bin/env bash
# Local main-train image build (#486, owner decision 13 of 2026-10-03).
#
# The normal path is CI: the image is built once on main and promoted with a
# GitHub attestation (ADR-0023, amendment 2026-10-03). This script is the
# documented EXCEPTION for main trains only, i.e. a window in which the live
# server is stopped anyway (announced by OB-00), or an explicit owner order
# "Server aus, lokal bauen" for an urgent hotfix. It is never the way to build
# while the live world server is running. Runbook:
# docs/runbooks/local-maintrain-image-build.md
#
# What it does, in order:
#   1. refuses outside the allowed window (23:30-00:30 UTC always; 00:30-08:00
#      UTC unless --owner-night-order),
#   2. refuses unless the source is a full, clean, LF-only clone of
#      github.com/Cilverkrow/twow-repo whose HEAD is on a freshly fetched
#      origin/main (the Dockerfile copies .git into the build, so a linked
#      worktree, a dirty tree or CRLF checkout would produce an image whose
#      provenance does not describe it),
#   3. refuses if any mangosd container is running, if another build container
#      is running, or if the host build lock exists,
#   4. creates or reuses a docker-container buildx builder named
#      <prefix>-maintrain-build with a CPU quota of --cpus (12..14),
#   5. builds deploy/docker/Dockerfile.core --target runtime with
#      BUILD_JOBS=<cpus>, the same OCI labels publish.yml sets, provenance
#      mode=max and an SBOM, and (if the Dockerfile has it) the debug-symbols
#      target as a separate image,
#   6. writes local-digest.json (builder=local-maintrain) and prints the
#      commands that verify provenance, SBOM and labels of the pushed digest.
#
# Credentials: the script never reads, prints or stores a token. --push only
# works if the operator has already run `docker login ghcr.io` himself; if that
# is missing the push fails and so does the script.
#
# Usage:
#   ops/build/local-maintrain-image.sh --name-prefix ob30 --reason "Zug 9, #319" [options]
#   ops/build/local-maintrain-image.sh --help
#
# Exit codes: 0 ok, 1 build/push failed, 2 usage error, 3 refused by a guard.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DOCKER=${TWOW_DOCKER:-docker}            # test seam: contract test injects a fake
REGISTRY=ghcr.io
OWNER=cilverkrow
SOURCE_URL=https://github.com/Cilverkrow/twow-repo
Y_BUILDS="/y/backup twwow/workspace-relocation-20260902/builds"

usage() {
    cat <<'EOF'
Usage: ops/build/local-maintrain-image.sh --name-prefix <chat> --reason <text> [options]

Only for main-train windows with the live server stopped, or on the explicit
owner order "Server aus, lokal bauen". See docs/runbooks/local-maintrain-image-build.md.

Required:
  --name-prefix P      chat prefix, e.g. ob30; builder = P-maintrain-build
  --reason TEXT        why this build is allowed (train, #319/#486 reference);
                       recorded in local-digest.json

Options:
  --cpus N             CPU quota of the builder and BUILD_JOBS, 12..14 [12]
  --memory SIZE        memory limit of the builder container, e.g. 28g
                       [none: the Docker Desktop VM limit applies]
  --push               push to ghcr.io/cilverkrow/{mangosd,realmd}:local-sha-<40>
                       (needs a prior `docker login ghcr.io` by the operator).
                       Without --push the image is only --load'ed locally, has
                       no attestations and must not be deployed.
  --source DIR         full clone to build [the repository containing this script]
  --out-dir DIR        where local-digest.json and metadata go
                       [Y:\backup twwow\...\builds\P-maintrain-<sha12>]
  --lock-file PATH     host build lock [Y:\backup twwow\...\builds\HOST-BUILD.lock]
  --allow-unmerged     build a HEAD that is not on origin/main (pin-PR rehearsal);
                       recorded as on_main=false, never deployable
  --debug-target NAME  Dockerfile target for split debug symbols [debug-symbols];
                       built only if the Dockerfile defines it
  --no-debug           do not build the debug-symbols target
  --owner-night-order  allow 00:30-08:00 UTC (owner ordered a night build);
                       23:30-00:30 UTC stays refused
  --dry-run            run every non-Docker guard, print the Docker commands,
                       call no Docker command at all
  -h, --help           this text
EOF
}

die()    { echo "ERROR: $*" >&2; exit 2; }
refuse() { echo "REFUSED: $*" >&2; exit 3; }
info()   { echo "== $*"; }

# ------------------------------------------------------------------ args ----
prefix='' reason='' cpus=12 memory='' push=0 dry=0 src='' out_dir='' lock_file=''
allow_unmerged=0 debug_target=debug-symbols no_debug=0 night_ok=0
lock_set=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --name-prefix)       [[ $# -ge 2 ]] || die "$1 needs a value"; prefix=$2; shift 2 ;;
        --reason)            [[ $# -ge 2 ]] || die "$1 needs a value"; reason=$2; shift 2 ;;
        --cpus)              [[ $# -ge 2 ]] || die "$1 needs a value"; cpus=$2; shift 2 ;;
        --memory)            [[ $# -ge 2 ]] || die "$1 needs a value"; memory=$2; shift 2 ;;
        --source)            [[ $# -ge 2 ]] || die "$1 needs a value"; src=$2; shift 2 ;;
        --out-dir)           [[ $# -ge 2 ]] || die "$1 needs a value"; out_dir=$2; shift 2 ;;
        --lock-file)         [[ $# -ge 2 ]] || die "$1 needs a value"; lock_file=$2; lock_set=1; shift 2 ;;
        --main-ref)          die "--main-ref was removed: only origin/main of Cilverkrow/twow-repo is deployable (see runbook)" ;;
        --debug-target)      [[ $# -ge 2 ]] || die "$1 needs a value"; debug_target=$2; shift 2 ;;
        --push)              push=1; shift ;;
        --dry-run)           dry=1; shift ;;
        --allow-unmerged)    allow_unmerged=1; shift ;;
        --no-debug)          no_debug=1; shift ;;
        --owner-night-order) night_ok=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)                   usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -n "$prefix" ]] || die "--name-prefix is required (e.g. ob30)"
[[ "$prefix" =~ ^[a-z][a-z0-9-]{1,23}$ ]] || die "--name-prefix must match ^[a-z][a-z0-9-]{1,23}\$: $prefix"
[[ -n "$reason" ]] || die "--reason is required (train and #319/#486 reference)"
[[ "$cpus" =~ ^[0-9]+$ ]] && (( cpus >= 12 && cpus <= 14 )) \
    || die "--cpus must be 12, 13 or 14 (owner decision 13); with the live server up the 4-CPU rule applies and this script is the wrong tool"
[[ -z "$memory" || "$memory" =~ ^[0-9]+[mMgG]$ ]] || die "--memory must look like 28g or 24000m: $memory"
[[ "$debug_target" =~ ^[A-Za-z0-9._-]+$ ]] || die "--debug-target has invalid characters"

builder="${prefix}-maintrain-build"
buildkit_container="buildx_buildkit_${builder}0"

# ----------------------------------------------------------- time window ----
# TWOW_TEST_NOW_HHMM is a test seam for the contract test only.
now_hhmm=${TWOW_TEST_NOW_HHMM:-$(date -u +%H%M)}
[[ "$now_hhmm" =~ ^[0-2][0-9][0-5][0-9]$ ]] || die "bad time: $now_hhmm"
now_min=$(( 10#${now_hhmm:0:2} * 60 + 10#${now_hhmm:2:2} ))
if (( now_min >= 23 * 60 + 30 || now_min < 30 )); then
    refuse "23:30-00:30 UTC is a no-build window (honor/auto-restart and DB jobs); it is ${now_hhmm} UTC"
fi
if (( now_min < 8 * 60 )) && (( night_ok == 0 )); then
    refuse "00:30-08:00 UTC: no local builds or containers without an explicit owner order (--owner-night-order); it is ${now_hhmm} UTC"
fi

# -------------------------------------------------------- source checks ----
[[ -n "$src" ]] || src=$(cd "$HERE/../.." && pwd)
[[ -d "$src" ]] || die "--source is not a directory: $src"
src=$(cd "$src" && pwd)
dockerfile="$src/deploy/docker/Dockerfile.core"
[[ -f "$dockerfile" ]] || refuse "no deploy/docker/Dockerfile.core in $src"

# The builder stage does COPY . /src and runs git inside /src/core, whose .git
# file must point into /src/.git/modules/core. A linked worktree has a .git
# FILE pointing at a host path that does not exist in the build.
[[ -d "$src/.git" ]] || refuse "$src is not a full clone (.git is not a directory - a linked worktree cannot be built, see runbook)"
[[ -f "$src/core/.git" ]] || refuse "core submodule not initialised in $src (git submodule update --init --recursive)"
grep -Eq '^gitdir: \.\./\.git/modules/core/?$' "$src/core/.git" \
    || refuse "core/.git does not point at ../.git/modules/core (relative); the revision header would break inside the build"
[[ -n "$(ls -A "$src/core/src/modules/Eluna" 2>/dev/null || true)" ]] \
    || refuse "core/src/modules/Eluna is empty: the checkout is not recursive"

for repo in "$src" "$src/core"; do
    acrlf=$(git -C "$repo" config --get core.autocrlf || true)
    [[ "$acrlf" != "true" ]] \
        || refuse "core.autocrlf=true in $repo: shell scripts would enter the image with CRLF (clone with -c core.autocrlf=false)"
done

dirty=$(git -C "$src" status --porcelain --ignore-submodules=none --untracked-files=normal)
[[ -z "$dirty" ]] || refuse "source tree is not clean; the labels would not describe the image:
$dirty"

repo_sha=$(git -C "$src" rev-parse HEAD)
repo_tree=$(git -C "$src" rev-parse 'HEAD^{tree}')
core_sha=$(git -C "$src" ls-tree HEAD core | awk '$2 == "commit" { print $3 }')
[[ -n "$core_sha" ]] || refuse "HEAD has no core gitlink"
core_head=$(git -C "$src/core" rev-parse HEAD)
[[ "$core_head" == "$core_sha" ]] || refuse "core checkout $core_head differs from the gitlink $core_sha"

# "On main" is only meaningful for the canonical repository, freshly fetched:
# the image is labelled source=Cilverkrow/twow-repo and pushed into the same
# ghcr.io/cilverkrow packages, and for a local image local-digest.json is the
# only deploy gate. A fork clone or a stale/moved origin/main must not pass.
# `git remote get-url` expands insteadOf, so the URL checked is the URL fetched.
# TWOW_TEST_ORIGIN_RE is a test seam for the contract test only.
origin_re=${TWOW_TEST_ORIGIN_RE:-'^(https://github\.com/|git@github\.com:)Cilverkrow/twow-repo(\.git)?/?$'}
[[ -z "${TWOW_TEST_ORIGIN_RE:-}" ]] || echo "WARNING: TWOW_TEST_ORIGIN_RE is set (contract-test seam); never use it for a real build" >&2
origin_url=$(git -C "$src" remote get-url origin 2>/dev/null || true)
[[ -n "$origin_url" ]] || refuse "$src has no remote 'origin'"
[[ "$origin_url" =~ $origin_re ]] \
    || refuse "origin of $src is '$origin_url', not https://github.com/Cilverkrow/twow-repo; only the canonical repository is built (clone it as in the runbook)"
git -C "$src" -c core.autocrlf=false fetch --quiet --no-tags origin '+refs/heads/main:refs/remotes/origin/main' \
    || refuse "git fetch origin main failed in $src; on_main cannot be decided without a fresh origin/main"
origin_main=$(git -C "$src" rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}' || true)
[[ -n "$origin_main" ]] || refuse "origin/main is unknown in $src after the fetch"

on_main=true
if ! git -C "$src" merge-base --is-ancestor "$repo_sha" "$origin_main"; then
    (( allow_unmerged == 1 )) || refuse "HEAD $repo_sha is not on origin/main ($origin_main); only main commits are built for a train (--allow-unmerged for a non-deployable rehearsal)"
    on_main=false
fi

build_debug=0
if (( no_debug == 0 )) && grep -Eiq "^FROM[[:space:]].*[[:space:]]AS[[:space:]]+${debug_target}([[:space:]]|\$)" "$dockerfile"; then
    build_debug=1
fi

if [[ -z "$out_dir" ]]; then
    [[ -d "$Y_BUILDS" ]] || die "no --out-dir given and $Y_BUILDS does not exist"
    out_dir="$Y_BUILDS/${prefix}-maintrain-${repo_sha:0:12}"
fi
if (( lock_set == 0 )) && [[ -d "$Y_BUILDS" ]]; then
    lock_file="$Y_BUILDS/HOST-BUILD.lock"
fi

tag="local-sha-${repo_sha}"
version="sha-${repo_sha}"
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if (( push == 1 )); then
    runtime_tags=("$REGISTRY/$OWNER/mangosd:$tag" "$REGISTRY/$OWNER/realmd:$tag")
    debug_tags=("$REGISTRY/$OWNER/mangosd-debug:$tag")
else
    runtime_tags=("twow-local/mangosd:$tag")
    debug_tags=("twow-local/mangosd-debug:$tag")
fi

info "builder=$builder (container $buildkit_container) cpus=$cpus memory=${memory:-vm-limit} push=$push dry_run=$dry"
info "repo=$repo_sha core=$core_sha tree=$repo_tree on_main=$on_main (origin/main=$origin_main, $origin_url)"
info "debug-symbols target '$debug_target': $( (( build_debug == 1 )) && echo build || echo skip )"
info "out_dir=$out_dir lock=${lock_file:-none}"

# ---------------------------------------------------------- docker calls ----
# run prints every Docker command; in --dry-run it only prints.
run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    (( dry == 1 )) && return 0
    "$@"
}

if (( dry == 1 )); then
    info "dry-run: Docker guards that would run:"
    echo "+ $DOCKER info --format '{{.MemTotal}}'"
    echo "+ $DOCKER ps --filter label=com.docker.compose.service=mangosd --format '{{.Names}} {{.Label \"com.docker.compose.project\"}}'"
    echo "+ $DOCKER ps --format '{{.Names}} {{.Image}}'   # refuse on any mangosd image or build container"
    echo "+ test ! -e ${lock_file:-<no lock file>}"
    echo "+ $DOCKER buildx inspect $builder   # reuse only if docker-container with cpu-quota=$(( cpus * 100000 ))"
else
    command -v "$DOCKER" >/dev/null 2>&1 || refuse "docker CLI not found"
    mem_total=$("$DOCKER" info --format '{{.MemTotal}}') || refuse "docker daemon not reachable"

    # Live server: refuse if ANY mangosd runs, live (ws50-roster-*) or a test
    # stack - the point of this window is that the host is free.
    running=$("$DOCKER" ps --filter label=com.docker.compose.service=mangosd \
        --format '{{.Names}} {{.Label "com.docker.compose.project"}}')
    [[ -z "$running" ]] || refuse "a mangosd container is running (live server must be stopped):
$running"
    all=$("$DOCKER" ps --format '{{.Names}} {{.Image}}')
    hits=$(awk '$2 ~ /mangosd/ { print }' <<<"$all")
    [[ -z "$hits" ]] || refuse "a container from a mangosd image is running:
$hits"
    # Our own builder container is left out: it is reused below, and the host
    # lock already enforces one build at a time. A leftover from an aborted run
    # must not block the rerun.
    builds=$(awk -v own="$buildkit_container" '$1 != own && ($1 ~ /^buildx_buildkit_/ || $1 ~ /-build(-|$)/ || $1 ~ /maintrain/) { print }' <<<"$all")
    [[ -z "$builds" ]] || refuse "another build container is running (one build at a time):
$builds"

    need=$(( cpus * 1610612736 ))   # 1.5 GiB per job, heavy units peak at 1.5-2.5 GiB
    if [[ "$mem_total" =~ ^[0-9]+$ ]] && (( mem_total < need )); then
        echo "WARNING: Docker reports $(( mem_total / 1048576 )) MiB, less than ~1.5 GiB per job for $cpus jobs; an OOM shows up as 'buildkitd EOF' (Dockerfile.core comment)" >&2
    fi
fi

# On every exit (guard refusal, failed build, missing digest, signal): stop our
# buildkitd so it does not keep the 12-14 CPU quota (its state/cache is kept),
# and remove our own lock file. builder_up/lock_written are set only once that
# resource is ours.
lock_written='' builder_up=''
cleanup() {
    if [[ -n "$builder_up" ]]; then
        echo "+ $DOCKER buildx stop $builder   # exit cleanup"
        "$DOCKER" buildx stop "$builder" >/dev/null 2>&1 || true
    fi
    if [[ -n "$lock_written" ]]; then rm -f "$lock_written"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -n "$lock_file" ]]; then
    if (( dry == 1 )); then
        [[ ! -e "$lock_file" ]] || echo "NOTE: lock file exists now - a real run would refuse: $lock_file"
    else
        [[ ! -e "$lock_file" ]] && (set -C; printf 'chat=%s task=maintrain-image start_utc=%s pid=%s\n' \
            "$prefix" "$created" "$$" > "$lock_file") 2>/dev/null \
            || refuse "host build lock exists: $lock_file ($(cat "$lock_file" 2>/dev/null || true))"
        lock_written=$lock_file
    fi
fi

# Builder. docker-container driver options (buildx docs, "docker-container
# driver"): cpu-period/cpu-quota/cpuset-cpus/cpu-shares/memory/memory-swap.
# These were added in buildx 0.12; check `docker buildx version` and
# `docker buildx create --help` against the installed version before the
# first run (runbook). The quota limits buildkitd and every compiler it spawns.
quota=$(( cpus * 100000 ))
create_cmd=("$DOCKER" buildx create --name "$builder" --driver docker-container
    --driver-opt cpu-period=100000 --driver-opt "cpu-quota=$quota")
if [[ -n "$memory" ]]; then
    create_cmd+=(--driver-opt "memory=$memory" --driver-opt "memory-swap=$memory")
fi
create_cmd+=(--bootstrap)

if (( dry == 1 )); then
    run "${create_cmd[@]}"
elif inspect=$("$DOCKER" buildx inspect "$builder" 2>/dev/null); then
    grep -Eq 'Driver:[[:space:]]+docker-container' <<<"$inspect" \
        || refuse "builder $builder exists but is not a docker-container builder"
    grep -Eq "cpu-quota=\"?${quota}\"?" <<<"$inspect" \
        || refuse "builder $builder exists with a different CPU quota; recreate it keeping its cache:
  $DOCKER buildx rm --keep-state $builder"
    info "reusing builder $builder (ccache and layer cache kept in its state volume)"
    builder_up=1
else
    builder_up=1   # also if create fails half-way after starting the container
    run "${create_cmd[@]}"
fi

mkdir_out() { if (( dry == 1 )); then echo "+ mkdir -p $out_dir"; else mkdir -p "$out_dir"; fi; }
mkdir_out

labels=(
    --label "org.opencontainers.image.created=$created"
    --label "org.opencontainers.image.licenses=AGPL-3.0"
    --label "org.opencontainers.image.revision=$repo_sha"
    --label "org.opencontainers.image.source=$SOURCE_URL"
    --label "org.opencontainers.image.url=$SOURCE_URL"
    --label "org.opencontainers.image.title=twow-repo"
    --label "org.opencontainers.image.version=$version"
    --label "io.twow.core.revision=$core_sha"
    --label "io.twow.build.origin=local-maintrain"
)

# build_target <target> <metadata-file> <tags...>
build_target() {
    local target=$1 meta=$2; shift 2
    local cmd=("$DOCKER" buildx build --builder "$builder"
        --file "$dockerfile" --target "$target"
        --build-arg BUILD_TYPE=Release --build-arg "BUILD_JOBS=$cpus"
        "${labels[@]}" --metadata-file "$meta")
    local t
    for t in "$@"; do cmd+=(--tag "$t"); done
    if (( push == 1 )); then
        cmd+=(--provenance=mode=max --sbom=true --push)
    else
        # The docker exporter cannot carry attestations; a --load image is a
        # local smoke artefact only.
        cmd+=(--provenance=false --sbom=false --load)
    fi
    cmd+=("$src")
    run "${cmd[@]}"
}

digest_of() {   # digest_of <metadata-file>; prints nothing if there is no digest
    (( dry == 1 )) && { echo "sha256:<dry-run>"; return 0; }
    { grep -o '"containerimage\.digest"[[:space:]]*:[[:space:]]*"sha256:[0-9a-f]\{64\}"' "$1" 2>/dev/null \
        | grep -o 'sha256:[0-9a-f]\{64\}' | head -n1; } || true
}

started=$(date +%s)
build_target runtime "$out_dir/runtime.metadata.json" "${runtime_tags[@]}" \
    || { echo "ERROR: runtime build/push failed (cache is kept; a rerun is fast)" >&2; exit 1; }
runtime_digest=$(digest_of "$out_dir/runtime.metadata.json")
[[ -n "$runtime_digest" ]] || { echo "ERROR: no containerimage.digest in runtime.metadata.json" >&2; exit 1; }

debug_digest=''
if (( build_debug == 1 )); then
    build_target "$debug_target" "$out_dir/debug.metadata.json" "${debug_tags[@]}" \
        || { echo "ERROR: debug-symbols build/push failed; runtime image $runtime_digest is built/pushed but NOT recorded (no local-digest.json) - rerun" >&2; exit 1; }
    debug_digest=$(digest_of "$out_dir/debug.metadata.json")
    [[ -n "$debug_digest" ]] || { echo "ERROR: no containerimage.digest in debug.metadata.json; runtime image $runtime_digest is NOT recorded (no local-digest.json) - rerun" >&2; exit 1; }
fi
elapsed=$(( $(date +%s) - started ))

# Stop buildkitd so it does not hold the CPU quota; state (cache) is kept.
run "$DOCKER" buildx stop "$builder" || true
builder_up=''

json_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/ }; printf '"%s"' "$s"; }
digest_json="$out_dir/local-digest.json"
write_json() {
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "builder": "local-maintrain",\n'
    printf '  "pushed": %s,\n' "$( (( push == 1 )) && echo true || echo false )"
    printf '  "deployable": %s,\n' "$( (( push == 1 )) && [[ $on_main == true ]] && echo true || echo false )"
    printf '  "repository": "Cilverkrow/twow-repo",\n'
    printf '  "revision": "%s",\n' "$repo_sha"
    printf '  "tree": "%s",\n' "$repo_tree"
    printf '  "core_revision": "%s",\n' "$core_sha"
    printf '  "on_main": %s,\n' "$on_main"
    printf '  "main_ref": "refs/remotes/origin/main",\n'
    printf '  "origin_url": %s,\n' "$(json_str "$origin_url")"
    printf '  "origin_main": "%s",\n' "$origin_main"
    printf '  "images": {\n'
    printf '    "mangosd": %s,\n' "$(json_str "${REGISTRY}/${OWNER}/mangosd@${runtime_digest}")"
    printf '    "realmd": %s,\n' "$(json_str "${REGISTRY}/${OWNER}/realmd@${runtime_digest}")"
    if [[ -n "$debug_digest" ]]; then
        printf '    "mangosd_debug": %s\n' "$(json_str "${REGISTRY}/${OWNER}/mangosd-debug@${debug_digest}")"
    else
        printf '    "mangosd_debug": null\n'
    fi
    printf '  },\n'
    printf '  "digest": "%s",\n' "$runtime_digest"
    printf '  "tag": "%s",\n' "$tag"
    printf '  "build": {"dockerfile": "deploy/docker/Dockerfile.core", "target": "runtime", "BUILD_TYPE": "Release", "BUILD_JOBS": %s, "cpus": %s, "memory": %s, "provenance": "%s", "sbom": %s},\n' \
        "$cpus" "$cpus" "$(json_str "${memory:-vm-limit}")" \
        "$( (( push == 1 )) && echo mode=max || echo none)" "$( (( push == 1 )) && echo true || echo false )"
    printf '  "builder_name": "%s",\n' "$builder"
    printf '  "created": "%s",\n' "$created"
    printf '  "elapsed_seconds": %s,\n' "$elapsed"
    printf '  "reason": %s\n' "$(json_str "$reason")"
    printf '}\n'
}
if (( dry == 1 )); then
    echo "+ write $digest_json:"
    write_json
else
    write_json > "$digest_json"
    info "wrote $digest_json"
fi

ref="${REGISTRY}/${OWNER}/mangosd@${runtime_digest}"
cat <<EOF

== Verify before any deploy (no GitHub attestation exists for a local build):
  $DOCKER buildx imagetools inspect $ref --format '{{json .Provenance}}'
  $DOCKER buildx imagetools inspect $ref --format '{{json .SBOM}}'
  $DOCKER buildx imagetools inspect $ref --format '{{json .Image.Config.Labels}}'
   -> provenance must name this repo revision ($repo_sha) and target runtime;
      labels revision=$repo_sha, io.twow.core.revision=$core_sha,
      io.twow.build.origin=local-maintrain.
  Deploy by digest only ($runtime_digest), never by tag; record the digest and
  local-digest.json in #319 and #486.

== Cache housekeeping (keeps the ccache warm for the next main train):
  $DOCKER buildx du --builder $builder
  $DOCKER buildx prune --builder $builder --max-used-space 60gb -f   # buildx < 0.17: --keep-storage 60gb
EOF
(( push == 1 )) || echo "NOTE: not pushed - this image is a local artefact and must not be deployed."
