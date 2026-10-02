#!/usr/bin/env bash
# Contract for ops/live/release-digest.sh (#486 B5, owner decision 4): the
# deploy rule, evaluated against synthetic publish-digest.json files and a stub
# `gh` that answers the run/job lookups and records the attestation call. No
# network, no Docker, no jq.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/ops/live/release-digest.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

REPO=Cilverkrow/twow-repo
hex64() { printf "%064d" 0 | tr 0 "$1"; }
D=sha256:$(hex64 a)
SHA=0123456789abcdef0123456789abcdef01234567
OLD=89abcdef0123456789abcdef0123456789abcdef
CORE=fedcba9876543210fedcba9876543210fedcba98
PROMOTE="$REPO/.github/workflows/promote.yml"
PUBLISH="$REPO/.github/workflows/publish.yml"

# Stub gh. Answers from files in $STUB: ci-run (the "<id> <conclusion>" line
# for the ci push run lookup), jobs-<run id> (name=conclusion lines), and
# attest-rc (exit code of `attestation verify`). Every call is logged.
STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$WORK/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/calls"
case "$1 $2" in
    "api repos/"*)
        case "$2" in
            */actions/workflows/ci.yml/runs*) cat "$STUB/ci-run" 2>/dev/null; exit 0 ;;
            */actions/runs/*/jobs*)
                id=${2#*/actions/runs/}; id=${id%%/*}
                cat "$STUB/jobs-$id" 2>/dev/null || exit 1; exit 0 ;;
        esac ;;
    "attestation verify") exit "$(cat "$STUB/attest-rc" 2>/dev/null || echo 0)" ;;
esac
echo "stub gh: unexpected call: $*" >&2
exit 9
EOF
chmod +x "$WORK/gh"
export STUB TWOW_GH="$WORK/gh"

reset_stub() {
    rm -f "$STUB"/*
    echo "500 success" > "$STUB/ci-run"
    printf '%s\n' 'build + test=success' 'compose up + smoke=success' 'lint=success' > "$STUB/jobs-500"
    printf '%s\n' 'build + test=success' 'compose up + smoke=success' > "$STUB/jobs-400"
    echo 0 > "$STUB/attest-rc"
}

# publish-digest.json as promote.yml writes it (pretty-printed by jq there).
record() {
    local file=$1; shift
    local workflow="$PROMOTE@refs/heads/main" source=promoted bt=success smoke=success
    local ti=true pr_smoke=success pr_run='"400"' reused_from="" image=ghcr.io/cilverkrow/mangosd digest=$D
    local kv
    for kv in "$@"; do
        case "$kv" in
            workflow=*) workflow=${kv#*=} ;; source=*) source=${kv#*=} ;;
            bt=*) bt=${kv#*=} ;; smoke=*) smoke=${kv#*=} ;; ti=*) ti=${kv#*=} ;;
            pr_smoke=*) pr_smoke=${kv#*=} ;; pr_run=*) pr_run=${kv#*=} ;;
            reused_from=*) reused_from=${kv#*=} ;; image=*) image=${kv#*=} ;;
            digest=*) digest=${kv#*=} ;;
        esac
    done
    cat > "$WORK/$file" <<EOF
{
  "repo_sha": "$SHA",
  "core_sha": "$CORE",
  "image": "$image",
  "digest": "$digest",
  "workflow": "$workflow",
  "run_id": "900",
  "built_at": "2026-10-03T10:00:00Z",
  "images": [
    "$image",
    "ghcr.io/cilverkrow/realmd"
  ],
  "source": "$source",
  "reused_from": "$reused_from",
  "ci_run_id": "500",
  "main_build_test": "$bt",
  "main_smoke": "$smoke",
  "smoke_pending": false,
  "tree_identical": $ti,
  "pin_pr": 42,
  "pin_pr_run_id": $pr_run,
  "pin_pr_smoke": "$pr_smoke",
  "build_input": "$(hex64 b)",
  "debug_image": "ghcr.io/cilverkrow/mangosd-debug",
  "debug_digest": "sha256:$(hex64 c)"
}
EOF
}

expect() {
    local want=$1 name=$2 rc=0
    shift 2
    bash "$SCRIPT" "$@" > "$WORK/$name.out" 2> "$WORK/$name.err" || rc=$?
    if [ "$rc" -ne "$want" ]; then
        echo "FAIL: $name - expected rc=$want, got rc=$rc" >&2
        cat "$WORK/$name.out" "$WORK/$name.err" >&2
        exit 1
    fi
    echo "$name=rc$want"
}
fail() { echo "FAIL: $*" >&2; exit 1; }

# ------------------------------------------------------------ the normal case
reset_stub
record ok.json
expect 0 promoted_online "$WORK/ok.json"
grep -qx "DIGEST=$D" "$WORK/promoted_online.out" || fail "digest not printed"
grep -qx "RELEASE=OK" "$WORK/promoted_online.out" || fail "RELEASE=OK not printed"
grep -qx "SIGNER=$PROMOTE" "$WORK/promoted_online.out" || fail "signer not promote.yml"
# The exact verification decision 4 prescribes.
grep -qx "attestation verify oci://ghcr.io/cilverkrow/mangosd@$D --repo $REPO --signer-workflow $PROMOTE --source-ref refs/heads/main --deny-self-hosted-runners" \
    "$STUB/calls" || { cat "$STUB/calls" >&2; fail "attestation verify not called as the rule says"; }
# The rule's inputs are re-read for the built commit, not taken from the file.
grep -q "ci.yml/runs?event=push&branch=main&head_sha=$SHA" "$STUB/calls" || fail "ci run of $SHA not looked up"
grep -q "actions/runs/400/jobs" "$STUB/calls" || fail "pin PR run not looked up"

reset_stub
expect 0 fill_args --fill-args "$WORK/ok.json"
[ "$(cat "$WORK/fill_args.out")" = "${SHA:0:8} ${CORE:0:8} $D" ] || fail "fill args: $(cat "$WORK/fill_args.out")"

# Same file in compact JSON (no line breaks) parses the same.
tr -d '\n' < "$WORK/ok.json" > "$WORK/compact.json"
reset_stub
expect 0 compact_json "$WORK/compact.json"

# ------------------------------------------------------------- rule branches
# Main smoke red, but tree identical and pin PR smoke green: releasable.
reset_stub
printf '%s\n' 'build + test=success' 'compose up + smoke=failure' > "$STUB/jobs-500"
expect 0 tree_branch "$WORK/ok.json"
grep -q 'tree identical to the pin PR' "$WORK/tree_branch.err" || fail "tree branch not reported"

# Tree different and main smoke red: no.
record tree-diff.json ti=false
reset_stub
printf '%s\n' 'build + test=success' 'compose up + smoke=failure' > "$STUB/jobs-500"
expect 3 tree_diff_smoke_red "$WORK/tree-diff.json"

# Tree identical but pin PR smoke red, main smoke red: no.
reset_stub
printf '%s\n' 'build + test=success' 'compose up + smoke=failure' > "$STUB/jobs-500"
printf '%s\n' 'build + test=success' 'compose up + smoke=failure' > "$STUB/jobs-400"
expect 3 pin_smoke_red "$WORK/ok.json"

# Tree unknown (null), main smoke green: releasable through the second branch.
record tree-null.json ti=null pr_run='""' pr_smoke=none
reset_stub
expect 0 tree_null_main_smoke "$WORK/tree-null.json"

# The file claims green, the API says build + test failed: the API wins.
reset_stub
printf '%s\n' 'build + test=failure' 'compose up + smoke=skipped' > "$STUB/jobs-500"
expect 3 api_overrides_file "$WORK/ok.json"

# No ci push run for the commit at all.
reset_stub
: > "$STUB/ci-run"
expect 3 no_ci_run "$WORK/ok.json"

# Lookup failure is not "not releasable".
reset_stub
rm "$STUB/jobs-500"
expect 5 jobs_lookup_fails "$WORK/ok.json"

# ------------------------------------------------------------- attestation
reset_stub
echo 1 > "$STUB/attest-rc"
expect 4 attestation_fails "$WORK/ok.json"

# ------------------------------------------------------------- offline
record off-red.json bt=failure
reset_stub
expect 3 offline_red --offline "$WORK/off-red.json"
reset_stub
expect 0 offline_green --offline "$WORK/ok.json"
grep -qx "RELEASE=OK_OFFLINE_UNVERIFIED" "$WORK/offline_green.out" || fail "offline result not marked unverified"
[ ! -s "$STUB/calls" ] || fail "offline mode called gh: $(cat "$STUB/calls")"
expect 2 offline_fill_args --offline --fill-args "$WORK/ok.json"

# ------------------------------------------------------------- record kinds
record reused.json source=reused reused_from=$OLD
reset_stub
expect 3 reused_refused "$WORK/reused.json"
grep -q "$OLD" "$WORK/reused_refused.err" || fail "reuse refusal does not name the original commit"

# A version tag on a promoted digest: verified as promote.yml/main, rule for
# the commit the image was built from.
record retag.json workflow="$PUBLISH@refs/tags/v1.2.3" source=retagged reused_from=$OLD
reset_stub
expect 0 retagged "$WORK/retag.json"
grep -q "head_sha=$OLD" "$STUB/calls" || fail "retagged: rule not evaluated for the built commit"
grep -q -- "--signer-workflow $PROMOTE --source-ref refs/heads/main" "$STUB/calls" || fail "retagged: not verified as a promotion"

# The from-source fallback needs --fallback-tag and verifies with the tag ref.
record fallback.json workflow="$PUBLISH@refs/tags/v1.2.3" source=from-source
reset_stub
expect 3 fallback_without_flag "$WORK/fallback.json"
reset_stub
expect 0 fallback_with_flag --fallback-tag "$WORK/fallback.json"
grep -q -- "--signer-workflow $PUBLISH --source-ref refs/tags/v1.2.3 --deny-self-hosted-runners" "$STUB/calls" \
    || fail "fallback not verified against publish.yml and the tag ref"

# Not deploy sources.
record pub-main.json workflow="$PUBLISH@refs/heads/main" source=from-source
reset_stub
expect 3 publish_from_main "$WORK/pub-main.json"
record branch.json workflow="$PROMOTE@refs/heads/feature"
reset_stub
expect 3 promote_from_branch "$WORK/branch.json"
record fork.json workflow="Someone/twow-repo/.github/workflows/promote.yml@refs/heads/main"
reset_stub
expect 3 foreign_signer "$WORK/fork.json"

# ------------------------------------------------------------- malformed
record bad-digest.json digest=sha256:1234
expect 2 bad_digest "$WORK/bad-digest.json"
record bad-image.json image=ghcr.io/someone/mangosd
expect 2 bad_image "$WORK/bad-image.json"
expect 2 missing_file "$WORK/nope.json"
expect 2 no_arguments

echo "release digest contract: ok"
