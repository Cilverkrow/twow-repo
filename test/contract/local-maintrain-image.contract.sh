#!/usr/bin/env bash
# Contract checks for ops/build/local-maintrain-image.sh (#486, owner decision
# 13). No Docker daemon is contacted: a fake `docker` on TWOW_DOCKER records
# every call, and the source is a throw-away git repository with a core
# submodule. The guards (time window, clean full clone, on main, running
# mangosd, build lock, builder quota) and the build command line are checked.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$root/ops/build/local-maintrain-image.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
g() { git -c user.name=t -c user.email=t@example.invalid -c core.autocrlf=false \
        -c protocol.file.allow=always -c init.defaultBranch=main "$@"; }

# ------------------------------------------------------------ fixtures ----
g init -q "$tmp/core"
mkdir -p "$tmp/core/src/modules/Eluna"
echo eluna > "$tmp/core/src/modules/Eluna/README"
g -C "$tmp/core" add -A && g -C "$tmp/core" commit -qm core

g init -q "$tmp/src"
g -C "$tmp/src" config core.autocrlf false
mkdir -p "$tmp/src/deploy/docker"
printf 'FROM debian AS builder\nFROM debian AS runtime\n' > "$tmp/src/deploy/docker/Dockerfile.core"
g -C "$tmp/src" submodule add -q "$tmp/core" core
g -C "$tmp/src/core" config core.autocrlf false
g -C "$tmp/src" add -A && g -C "$tmp/src" commit -qm platform
g -C "$tmp/src" update-ref refs/remotes/origin/main HEAD
sha=$(git -C "$tmp/src" rev-parse HEAD)
core_sha=$(git -C "$tmp/core" rev-parse HEAD)

# Fake docker: logs argv, answers ps from FAKE_PS, inspect from FAKE_INSPECT,
# and writes a metadata file for every build.
cat > "$tmp/docker" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1 ${2:-}" in
    "info "*)          echo 34359738368 ;;
    "ps "*)            if [[ "$*" == *com.docker.compose.service=mangosd* ]]; then
                           printf '%s' "${FAKE_PS_MANGOSD:-}"
                       else
                           printf '%s' "${FAKE_PS_ALL:-}"
                       fi ;;
    "buildx inspect")  [[ -n "${FAKE_INSPECT:-}" ]] || exit 1; printf '%s\n' "$FAKE_INSPECT" ;;
    "buildx build")    meta=''; prev=''
                       for a in "$@"; do [[ $prev == --metadata-file ]] && meta=$a; prev=$a; done
                       printf '{"containerimage.digest": "sha256:%064d"}\n' 7 > "$meta" ;;
esac
exit 0
FAKE
chmod +x "$tmp/docker"
export TWOW_DOCKER="$tmp/docker" FAKE_LOG="$tmp/calls" TWOW_TEST_NOW_HHMM=1200
base=(--name-prefix ob30 --reason "Zug 9 test" --source "$tmp/src" --out-dir "$tmp/out" --lock-file "$tmp/HOST-BUILD.lock")
rc() { local r=0; "$@" >"$tmp/stdout" 2>"$tmp/stderr" || r=$?; echo "$r"; }

# ---------------------------------------------------------------- usage ----
[[ $(rc bash "$script" --help) == 0 ]] || fail '--help exits 0'
[[ $(rc bash "$script" --reason x --dry-run) == 2 ]] || fail 'missing --name-prefix is a usage error'
[[ $(rc bash "$script" "${base[@]}" --cpus 8 --dry-run) == 2 ]] || fail '--cpus 8 is rejected'
[[ $(rc bash "$script" "${base[@]}" --cpus 16 --dry-run) == 2 ]] || fail '--cpus 16 is rejected'
pass 'usage: prefix required, --cpus only 12..14'

# ---------------------------------------------------------- time window ----
[[ $(TWOW_TEST_NOW_HHMM=2345 rc bash "$script" "${base[@]}" --dry-run) == 3 ]] || fail '23:45 UTC must be refused'
[[ $(TWOW_TEST_NOW_HHMM=0015 rc bash "$script" "${base[@]}" --dry-run --owner-night-order) == 3 ]] || fail '00:15 UTC refused even with owner order'
[[ $(TWOW_TEST_NOW_HHMM=0300 rc bash "$script" "${base[@]}" --dry-run) == 3 ]] || fail '03:00 UTC refused without owner order'
[[ $(TWOW_TEST_NOW_HHMM=0300 rc bash "$script" "${base[@]}" --dry-run --owner-night-order) == 0 ]] || fail '03:00 UTC allowed with owner order'
pass 'time window: 23:30-00:30 always refused, 00:30-08:00 only with owner order'

# -------------------------------------------------------------- dry-run ----
: > "$tmp/calls"
[[ $(rc bash "$script" "${base[@]}" --cpus 13 --push --dry-run) == 0 ]] || fail "dry-run must pass: $(cat "$tmp/stderr")"
[[ ! -s "$tmp/calls" ]] || fail "dry-run called docker: $(cat "$tmp/calls")"
out=$(cat "$tmp/stdout")
for want in 'cpu-quota=1300000' 'BUILD_JOBS=13' '--target runtime' '--provenance=mode=max' '--sbom=true' '--push' \
            "org.opencontainers.image.revision=$sha" "io.twow.core.revision=$core_sha" \
            "org.opencontainers.image.version=sha-$sha" "ghcr.io/cilverkrow/realmd:local-sha-$sha" \
            '"builder": "local-maintrain"' 'ob30-maintrain-build'; do
    grep -Fq -- "$want" <<<"$out" || fail "dry-run output lacks: $want"
done
[[ ! -e "$tmp/out" && ! -e "$tmp/HOST-BUILD.lock" ]] || fail 'dry-run wrote files'
pass 'dry-run calls no docker, writes nothing, prints quota/jobs/labels/provenance'

# --------------------------------------------------------------- source ----
echo dirty > "$tmp/src/untracked"
[[ $(rc bash "$script" "${base[@]}" --dry-run) == 3 ]] || fail 'dirty tree must be refused'
rm "$tmp/src/untracked"
g -C "$tmp/src" commit -q --allow-empty -m unmerged
[[ $(rc bash "$script" "${base[@]}" --dry-run) == 3 ]] || fail 'HEAD not on origin/main must be refused'
[[ $(rc bash "$script" "${base[@]}" --dry-run --allow-unmerged) == 0 ]] || fail '--allow-unmerged passes'
grep -Fq '"on_main": false' "$tmp/stdout" || fail 'unmerged build not recorded as on_main=false'
grep -Fq '"deployable": false' "$tmp/stdout" || fail 'unmerged build must not be deployable'
g -C "$tmp/src" reset -q --hard origin/main
g -C "$tmp/src" config core.autocrlf true
[[ $(rc bash "$script" "${base[@]}" --dry-run) == 3 ]] || fail 'core.autocrlf=true must be refused'
g -C "$tmp/src" config core.autocrlf false
g -C "$tmp/src" worktree add -q "$tmp/wt" HEAD 2>/dev/null
[[ $(rc bash "$script" "${base[@]/$tmp\/src/$tmp/wt}" --dry-run) == 3 ]] || fail 'linked worktree must be refused'
grep -q 'not a full clone' "$tmp/stderr" || fail "worktree refusal reason: $(cat "$tmp/stderr")"
pass 'source: dirty, unmerged, autocrlf=true and linked worktree are refused'

# ---------------------------------------------------------- live guards ----
: > "$tmp/calls"
[[ $(FAKE_PS_MANGOSD='ws50-roster-v24-mangosd-1 ws50-roster-v24' rc bash "$script" "${base[@]}") == 3 ]] \
    || fail 'running live mangosd must be refused'
! grep -q '^buildx' "$tmp/calls" || fail 'buildx was called although mangosd runs'
[[ $(FAKE_PS_ALL='ob30-test-mangosd-1 ghcr.io/cilverkrow/mangosd@sha256:aa' rc bash "$script" "${base[@]}") == 3 ]] \
    || fail 'container from a mangosd image must be refused'
[[ $(FAKE_PS_ALL='buildx_buildkit_ob40-x0 moby/buildkit' rc bash "$script" "${base[@]}") == 3 ]] \
    || fail 'running build container must be refused'
echo 'chat=ob40' > "$tmp/HOST-BUILD.lock"
[[ $(rc bash "$script" "${base[@]}") == 3 ]] || fail 'existing host build lock must be refused'
[[ $(cat "$tmp/HOST-BUILD.lock") == 'chat=ob40' ]] || fail 'foreign lock file was touched'
rm "$tmp/HOST-BUILD.lock"
[[ $(FAKE_INSPECT=$'Driver: docker-container\nDriver Options: cpu-period="100000" cpu-quota="400000"' \
     rc bash "$script" "${base[@]}") == 3 ]] || fail 'existing builder with another quota must be refused'
grep -q 'buildx rm --keep-state ob30-maintrain-build' "$tmp/stderr" || fail 'quota refusal lacks the recreate hint'
[[ ! -e "$tmp/HOST-BUILD.lock" ]] || fail 'own lock not removed after a refusal'
pass 'guards: live/test mangosd, build container, host lock, builder quota'

# ------------------------------------------------------------ real run ----
printf 'FROM debian AS debug-symbols\n' >> "$tmp/src/deploy/docker/Dockerfile.core"
g -C "$tmp/src" commit -qam 'debug target' && g -C "$tmp/src" update-ref refs/remotes/origin/main HEAD
sha=$(git -C "$tmp/src" rev-parse HEAD)
: > "$tmp/calls"
[[ $(rc bash "$script" "${base[@]}" --cpus 14 --memory 28g --push) == 0 ]] || fail "fake run failed: $(cat "$tmp/stderr")"
grep -q -- '^buildx create --name ob30-maintrain-build --driver docker-container --driver-opt cpu-period=100000 --driver-opt cpu-quota=1400000 --driver-opt memory=28g --driver-opt memory-swap=28g --bootstrap$' "$tmp/calls" \
    || fail "builder create line: $(grep create "$tmp/calls")"
[[ $(grep -c '^buildx build ' "$tmp/calls") == 2 ]] || fail 'expected runtime + debug-symbols builds'
grep '^buildx build ' "$tmp/calls" | head -1 | grep -q -- '--target runtime .*BUILD_JOBS=14.*--provenance=mode=max --sbom=true --push' \
    || fail 'runtime build line'
grep '^buildx build ' "$tmp/calls" | tail -1 | grep -q -- "--target debug-symbols .*--tag ghcr.io/cilverkrow/mangosd-debug:local-sha-$sha" \
    || fail 'debug build line'
grep -q '^buildx stop ob30-maintrain-build$' "$tmp/calls" || fail 'builder not stopped after the build'
j="$tmp/out/local-digest.json"
d="sha256:$(printf '%064d' 7)"
for want in '"builder": "local-maintrain"' "\"revision\": \"$sha\"" "\"digest\": \"$d\"" \
            "\"mangosd\": \"ghcr.io/cilverkrow/mangosd@$d\"" '"deployable": true' '"BUILD_JOBS": 14' \
            '"reason": "Zug 9 test"'; do
    grep -Fq -- "$want" "$j" || fail "local-digest.json lacks: $want"
done
[[ ! -e "$tmp/HOST-BUILD.lock" ]] || fail 'lock not removed after a successful run'
pass 'fake run: capped builder, runtime + debug image, local-digest.json, lock released'

: > "$tmp/calls"
[[ $(FAKE_INSPECT=$'Driver: docker-container\nDriver Options: cpu-period="100000" cpu-quota="1200000"' \
     rc bash "$script" "${base[@]}" --no-debug) == 0 ]] || fail 'reuse run failed'
! grep -q '^buildx create' "$tmp/calls" || fail 'matching builder must be reused, not recreated'
grep '^buildx build ' "$tmp/calls" | grep -q -- '--provenance=false --sbom=false --load' || fail 'no-push build must --load'
[[ $(grep -c '^buildx build ' "$tmp/calls") == 1 ]] || fail '--no-debug still built debug-symbols'
grep -Fq '"deployable": false' "$tmp/out/local-digest.json" || fail 'unpushed image must not be deployable'
pass 'reuse: matching builder kept, unpushed image marked not deployable'
