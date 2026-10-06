#!/usr/bin/env bash
# Container-free contract for the promotion path (#486 B5/B6, owner decisions
# 3b, 4 and 7): promote.yml, the artifacts ci.yml hands it, and publish.yml as
# the tag/dispatch fallback. Reads the files, builds nothing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"
PROMOTE="$ROOT/.github/workflows/promote.yml"
PUBLISH="$ROOT/.github/workflows/publish.yml"
ALLOWLIST="$ROOT/ops/ci/workflow-policy-allowlist.txt"

failures=0
fail() {
    echo "ERROR: $*" >&2
    failures=$((failures + 1))
}
code() { grep -v '^ *#' "$1"; }

# Lines of one job: from `  <name>:` to the next job key at the same indent.
job() {
    awk -v name="$2" '
        /^  [A-Za-z0-9_-]+:$/ { inside = ($0 == "  " name ":") ; if (inside) { print; next } }
        /^[^ #]/ { inside = 0 }
        inside { print }
    ' "$1"
}

[ -f "$PROMOTE" ] || { echo "ERROR: promote.yml is missing" >&2; exit 1; }

# ---------------------------------------------------------------- trigger
ci_name=$(sed -n 's/^name: *//p' "$CI" | head -1)
on_block=$(sed -n '/^on:/,/^[a-z]/p' "$PROMOTE")
printf '%s\n' "$on_block" | grep -q '^  workflow_run:$' || fail "promote.yml is not triggered by workflow_run"
printf '%s\n' "$on_block" | grep -Eq "^    workflows: \[$ci_name\]$" \
    || fail "promote.yml does not follow ci.yml's workflow (name '$ci_name')"
printf '%s\n' "$on_block" | grep -Eq '^    types: \[completed\]$' || fail "promote.yml is not types: [completed]"
printf '%s\n' "$on_block" | grep -Eq '^    branches: \[main\]$' || fail "promote.yml is not limited to branches: [main]"
if printf '%s\n' "$on_block" | grep -Eq '^  (push|pull_request|pull_request_target|issue_comment|workflow_dispatch|schedule):'; then
    fail "promote.yml has a trigger besides workflow_run"
fi
grep -Fqx 'workflow_run .github/workflows/promote.yml' "$ALLOWLIST" 2>/dev/null \
    || fail "ops/ci/workflow-policy-allowlist.txt does not admit promote.yml's workflow_run"

# ---------------------------------------------------------------- permissions
grep -qx 'permissions: {}' "$PROMOTE" || fail "promote.yml top-level permissions must be {}"
promote_job=$(job "$PROMOTE" promote)
[ -n "$promote_job" ] || fail "promote.yml has no job 'promote'"
perms=$(printf '%s\n' "$promote_job" | sed -n '/^    permissions:$/,/^    [a-z-]*:/p' \
    | grep -E '^      [a-z-]+: ' | sed 's/^ *//' | LC_ALL=C sort)
want=$(printf '%s\n' 'actions: read' 'attestations: write' 'contents: read' 'id-token: write' 'packages: write')
[ "$perms" = "$want" ] || fail "promote job permissions are not exactly: $(echo $want)"
jobs_count=$(grep -cE '^  [A-Za-z0-9_-]+:$' <(sed -n '/^jobs:/,$p' "$PROMOTE"))
[ "$jobs_count" -eq 1 ] || fail "promote.yml must have exactly one job (has $jobs_count)"

# ---------------------------------------------------------------- guard
guard=$(printf '%s\n' "$promote_job" | sed -n '/^    if: >-$/,/^    [a-z-]*:/p')
for cond in \
    "github.repository == 'Cilverkrow/twow-repo'" \
    "github.event.workflow_run.conclusion == 'success'" \
    "github.event.workflow_run.event == 'push'" \
    "github.event.workflow_run.head_branch == 'main'" \
    "github.event.workflow_run.head_repository.full_name == github.repository"; do
    printf '%s\n' "$guard" | grep -Fq "$cond" || fail "promote job guard lacks: $cond"
done
if printf '%s\n' "$guard" | grep -q '||'; then
    fail "promote job guard contains || - every condition must hold"
fi
runs_on=$(grep -E '^ +runs-on:' "$PROMOTE" | sed 's/^ *runs-on: *//' | LC_ALL=C sort -u)
[ "$runs_on" = ubuntu-latest ] || fail "promote.yml runs-on must be the literal ubuntu-latest"

# ---------------------------------------------------------------- pinning
check_pinned() {
    local label=$1 text=$2 line ref
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        ref=${line#*uses: }
        printf '%s\n' "$ref" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9][0-9.]*$' \
            || fail "$label: action not pinned to a full commit SHA with a tag comment: $ref"
    done < <(printf '%s\n' "$text" | grep -v '^ *#' | grep -E '^ +(- )?uses: ')
}
check_pinned promote.yml "$(cat "$PROMOTE")"
check_pinned "ci.yml build-and-test" "$(job "$CI" build-and-test)"
check_pinned "ci.yml capacity" "$(job "$CI" capacity)"
check_pinned "ci.yml scope" "$(job "$CI" scope)"

# ---------------------------------------------------------------- ordering
line_of() { grep -nF -- "$1" "$PROMOTE" | head -1 | cut -d: -f1; }
trust=$(line_of 'bash ops/ci/check-core-gitlink-trust.sh')
verify=$(line_of '- name: Verify the artifacts against the image record')
labels=$(line_of '- name: Load the image and check its labels')
login=$(line_of 'uses: docker/login-action@')
push=$(line_of '- name: Push the image')
debug=$(line_of '- name: Push the debug symbols image')
reuse=$(line_of '- name: Reuse the image of the same build input')
record=$(line_of '- name: Record the promoted digest')
for v in trust verify labels login push debug reuse record; do
    [ -n "${!v}" ] || fail "promote.yml lacks the step for '$v'"
done
if [ "$failures" -eq 0 ]; then
    [ "$trust" -lt "$login" ] || fail "core gitlink trust check must run before the registry login"
    [ "$verify" -lt "$push" ] && [ "$labels" -lt "$push" ] || fail "artifact and label checks must run before the push"
    [ "$push" -lt "$debug" ] || fail "debug symbols image must be pushed after the runtime image (it labels the runtime digest)"
    [ "$trust" -lt "$reuse" ] || fail "core gitlink trust check must run before the B5a reuse"
    last_attest=$(grep -nF 'uses: actions/attest-' "$PROMOTE" | tail -1 | cut -d: -f1)
    [ "$last_attest" -lt "$record" ] || fail "publish-digest.json must be written after every attestation"
fi
# ---------------------------------------------------------------- skip branch (#507)
# A commit from before the promote tooling (#500) is not an alarm: promote.yml
# runs from main but checks out the triggering commit, so it ends green with a
# notice. The skip branch must be the ONLY successful exit before the trust step
# and must not weaken the fail-closed path of a commit that has the tooling.
for tool in ops/ci/build-input-key.sh ops/ci/check-core-gitlink-trust.sh ops/live/release-digest.sh; do
    grep -Fq "$tool" <(code "$PROMOTE" | grep -F 'for f in') \
        || fail "promote.yml skip check does not test for $tool"
    [ -f "$ROOT/$tool" ] || fail "$tool is named by the promote skip check but does not exist"
done
skip_writes=$(code "$PROMOTE" | grep -Fc 'echo "skip=true" >> "$GITHUB_OUTPUT"' || true)
[ "$skip_writes" -eq 1 ] || fail "promote.yml must write skip=true exactly once (found $skip_writes)"
skip_line=$(line_of 'echo "skip=true" >> "$GITHUB_OUTPUT"' || true)
notice_line=$(line_of "predates promote tooling" || true)
mode_line=$(line_of 'echo "mode=$mode"' || true)
api_line=$(line_of 'actions/runs/$CI_RUN_ID" \' || true)
for v in skip_line notice_line mode_line api_line; do
    [ -n "${!v}" ] || fail "promote.yml lacks the skip branch marker for '$v' (#507)"
done
if [ "$failures" -eq 0 ]; then
    grep -Fq '::notice::commit' <(sed -n "${notice_line}p" "$PROMOTE") || fail "promote.yml skip branch does not print a ::notice::"
    [ "$notice_line" -lt "$skip_line" ] && [ "$skip_line" -lt "$api_line" ] \
        || fail "promote.yml skip branch must come before any API check of the ci run"
    [ "$skip_line" -lt "$mode_line" ] || fail "promote.yml must not set mode on the skip path"
    [ "$(sed -n "$((skip_line + 1))p" "$PROMOTE" | sed 's/^ *//')" = 'exit 0' ] \
        || fail "promote.yml skip branch must exit 0 right after writing skip=true"
    # The only `exit 0` ahead of the trust step is the skip branch's.
    exits_before_trust=$(sed -n "1,$((trust - 1))p" "$PROMOTE" | grep -v '^ *#' | grep -cE '(^|[^a-z])exit 0( |$)' || true)
    [ "$exits_before_trust" -eq 1 ] \
        || fail "promote.yml has $exits_before_trust successful exits before the trust step; only the skip branch may have one"
    # Every step with side effects or checks behind it honours the skip.
    for step in '- name: Core gitlink is on core main or release/*' '- name: Compare with the tested pin PR'; do
        n=$(line_of "$step")
        [ -n "$n" ] && [ "$(sed -n "$((n + 1))p" "$PROMOTE" | sed 's/^ *//')" = "if: steps.run.outputs.skip != 'true'" ] \
            || fail "promote.yml step '${step#- name: }' does not honour skip"
    done
    for action in docker/setup-buildx-action@ docker/login-action@; do
        n=$(line_of "uses: $action")
        [ -n "$n" ] && [ "$(sed -n "$((n - 1))p" "$PROMOTE" | sed 's/^ *- *//')" = "if: steps.run.outputs.skip != 'true'" ] \
            || fail "promote.yml step using $action does not honour skip"
    done
    # Behind the skip `mode` is empty, so every promote/reuse step is off by its own condition.
    gated=$(code "$PROMOTE" | grep -cE "^ +if: steps\.run\.outputs\.mode == '(promote|reuse)'" || true)
    [ "$gated" -ge 12 ] || fail "promote.yml promote/reuse steps lost their mode condition (found $gated)"
fi
grep -Fq "head_sha" <(sed -n '/- uses: actions\/checkout@/,/persist-credentials/p' "$PROMOTE") \
    || fail "promote.yml does not check out workflow_run.head_sha"
grep -Eq '^ +persist-credentials: false$' "$PROMOTE" || fail "promote.yml checkout keeps credentials"
grep -Fq '.github/workflows/ci.yml' "$PROMOTE" || fail "promote.yml does not check the triggering run's workflow path"

# Labels compared before pushing.
for l in org.opencontainers.image.revision org.opencontainers.image.source \
         org.opencontainers.image.version io.twow.core.revision io.twow.build-input; do
    grep -Fq "expect $l " "$PROMOTE" || fail "promote.yml does not check label $l"
done
# Artifacts taken from the triggering run, which must upload them.
for a in core-image debug-symbols image-record; do
    grep -Fq "name: $a" "$PROMOTE" || fail "promote.yml does not download $a"
    grep -Fq "name: $a" "$CI" || fail "ci.yml does not upload $a"
done
[ "$(grep -c 'run-id: ${{ github.event.workflow_run.id }}' "$PROMOTE")" -ge 3 ] \
    || fail "promote.yml must download every artifact from the triggering run (run-id)"

# The job names promote.yml reads must be ci.yml's.
for v in CI_BUILD_JOB CI_SMOKE_JOB; do
    name=$(sed -n "s/^  $v: *//p" "$PROMOTE")
    [ -n "$name" ] || { fail "promote.yml does not set $v"; continue; }
    grep -Eq "^    name: $(printf '%s' "$name" | sed 's/[+.]/\\&/g')\$" "$CI" \
        || fail "$v='$name' is not a job name in ci.yml"
done

# Debug symbols: own image, FROM scratch, never in the runtime image.
grep -Fq "printf 'FROM scratch\\nCOPY . /\\n'" "$PROMOTE" || fail "debug image is not FROM scratch"
grep -Fq 'mangosd-debug' "$PROMOTE" || fail "promote.yml does not push mangosd-debug"
grep -Eq 'imagetools create --prefer-index=false' "$PROMOTE" \
    || fail "promote.yml re-tags without --prefer-index=false (the digest would change)"
if code "$PROMOTE" | grep -Eq 'docker/build-push-action|cmake|ninja'; then
    fail "promote.yml must not build the server"
fi
# The deploy rule printed is decision 4, literally.
grep -Fq -- '--signer-workflow $GITHUB_REPOSITORY/.github/workflows/promote.yml' "$PROMOTE" \
    || fail "promote.yml summary does not name promote.yml as the signer"
grep -Fq -- '--source-ref refs/heads/main --deny-self-hosted-runners' "$PROMOTE" \
    || fail "promote.yml summary does not print --source-ref refs/heads/main --deny-self-hosted-runners"
for key in repo_sha core_sha image digest workflow run_id built_at tree_identical \
           pin_pr_smoke smoke_pending main_build_test main_smoke build_input debug_digest source; do
    grep -Eq -- "(--arg|--argjson) $key " "$PROMOTE" || fail "publish-digest.json from promote.yml lacks $key"
done

# ---------------------------------------------------------------- ci.yml
grep -Fq "retention-days: \${{ github.ref == 'refs/heads/main' && 3 || 1 }}" "$CI" \
    || fail "ci.yml core-image retention on main is not 3 days"
grep -Fqx '            io.twow.build-input=${{ steps.core-revision.outputs.build_input }}' "$CI" \
    || fail "ci-staged image lacks the io.twow.build-input label"
grep -Fq 'bash ops/ci/build-input-key.sh HEAD' "$CI" || fail "ci.yml does not compute the build-input key"
for f in commit tree pr_head_sha core_sha build_input core_image_sha256 run_id; do
    grep -Eq -- "--arg $f " "$CI" || fail "ci.yml image record lacks $f"
done

# ---------------------------------------------------------------- publish.yml
core_job=$(job "$PUBLISH" core)
printf '%s\n' "$core_job" | grep -Fqx "    if: github.event_name == 'workflow_dispatch'" \
    || fail "publish.yml core (from source) is not dispatch-only"
printf '%s\n' "$core_job" | grep -Fqx '    environment: release-publish' \
    || fail "publish.yml core does not use the environment release-publish"
# Only the core job: db-init keeps its own sha-<40> tag.
if printf '%s\n' "$core_job" | grep -v '^ *#' | grep -Eq 'type=sha,format=long,enable='; then
    fail "publish.yml core tags sha-<40>, which belongs to the promoted image (use src-sha-)"
fi
printf '%s\n' "$core_job" | grep -Fq 'type=sha,format=long,prefix=src-sha-,' \
    || fail "publish.yml from-source build is not tagged src-sha-<40>"
tag_job=$(job "$PUBLISH" release-tag)
[ -n "$tag_job" ] || fail "publish.yml has no release-tag job"
printf '%s\n' "$tag_job" | grep -Fq "startsWith(github.ref, 'refs/tags/v')" || fail "release-tag does not run for v* tags"
printf '%s\n' "$tag_job" | grep -Fq 'imagetools create --prefer-index=false' || fail "release-tag does not re-tag by digest"
printf '%s\n' "$tag_job" | grep -Fq -- '--signer-workflow "$GITHUB_REPOSITORY/.github/workflows/promote.yml"' \
    || fail "release-tag does not verify the promote.yml attestation before re-tagging"
if printf '%s\n' "$tag_job" | grep -v '^ *#' | grep -Eq 'build-push-action|id-token: write'; then
    fail "release-tag must neither build nor sign"
fi
for j in db-init helm; do
    job "$PUBLISH" "$j" | grep -q 'needs: discover' || fail "publish.yml $j no longer follows discover"
done
pub_on=$(sed -n '/^on:/,/^[a-z]/p' "$PUBLISH")
printf '%s\n' "$pub_on" | grep -q "branches: \[main\]" || fail "publish.yml no longer runs on main (db-init, helm)"
printf '%s\n' "$pub_on" | grep -q "tags: \['v\*'\]" || fail "publish.yml no longer runs on v* tags"

if [ "$failures" -ne 0 ]; then
    echo "promote workflow contract: $failures failure(s)" >&2
    exit 1
fi
printf '%s\n' 'promote_trigger=workflow_run_after_ci_on_main' 'promote_permissions=job_only' \
    'promote_actions=sha_pinned' 'promote_order=trust_verify_labels_push_attest_record' \
    'publish=dispatch_from_source_and_tag_retag'
