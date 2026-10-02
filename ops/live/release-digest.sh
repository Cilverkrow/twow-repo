#!/usr/bin/env bash
# Deploy rule for core images (#486 B5, owner decision 4): may this digest be
# deployed? Reads a publish-digest.json, applies the release rule, verifies the
# attestation, and prints the digest to pin.
#
#   release-digest.sh [--offline] [--fallback-tag] [--fill-args]
#                     [--repo OWNER/REPO] PUBLISH_DIGEST_JSON
#
# Get the file from the promote run of the commit (never resolve a tag - anyone
# who can push can move a tag):
#   gh run download <promote run id> -R Cilverkrow/twow-repo -n publish-digest
#
# THE RULE (decision 4):
#   1. The digest comes from publish-digest.json (or the attestation subject),
#      never from a tag.
#   2. Before the pull:
#        gh attestation verify oci://ghcr.io/cilverkrow/mangosd@<digest>
#          --repo Cilverkrow/twow-repo
#          --signer-workflow Cilverkrow/twow-repo/.github/workflows/promote.yml
#          --source-ref refs/heads/main --deny-self-hosted-runners
#      Fallback only with --fallback-tag: an image publish.yml built from source
#      when dispatched on a v* tag, signer publish.yml, --source-ref
#      refs/tags/v<...>.
#   3. Release only if main build+test is green AND
#        (the squash tree is identical to the tree the pin PR tested AND that
#         pin PR's smoke was green)  OR  the main smoke is green.
#      With promote.yml (decision 3b) the main smoke has already run when the
#      digest appears, so the second branch normally decides.
#   4. If the main smoke turns red later: stop the deploy or roll back.
#
# Which file is which (field `workflow` / `source`):
#   promote.yml@refs/heads/main, source promoted   the normal case
#   promote.yml@refs/heads/main, source reused     B5a: the image of an earlier
#       commit with the same build input; deploy that commit's record instead
#       (same digest, reused_from names it) - refused here
#   publish.yml@refs/tags/v*, source retagged      a version tag on a promoted
#       digest: verified as a promotion of reused_from (the built commit)
#   publish.yml@refs/tags/v*, source from-source   the fallback (--fallback-tag)
#   anything else                                  not a deploy source
#
# Online (default) the rule's inputs are re-read from the GitHub API, not taken
# from the file: the ci push run of the built commit on main (`build + test`,
# `compose up + smoke`) and the pin PR's ci run named in the file. Only
# tree_identical comes from the file (promote.yml computed it from the pin PR's
# image record). --offline evaluates the file alone and skips the attestation -
# a dry run for preparing a deploy, never the deploy decision itself.
#
# Output (stdout): DIGEST=, REPO_SHA=, CORE_SHA=, SIGNER=, SOURCE_REF=,
# RELEASE=OK. With --fill-args only "<repo sha8> <core sha8> <digest>", the
# arguments of the per-train fill-digest.sh:
#   bash fill-digest.sh $(ops/live/release-digest.sh --fill-args publish-digest.json)
# After the pull, the image's org.opencontainers.image.revision label must be
# the built commit (printed as a hint).
#
# Exit: 0 releasable and verified, 2 usage or malformed file, 3 the rule says
# no, 4 attestation verification failed, 5 a GitHub lookup failed.
# Needs bash, grep, sed and (online) gh. No jq: the Windows host has none.
# TWOW_GH overrides the gh command (tests).

set -euo pipefail

REPO="Cilverkrow/twow-repo"
OFFLINE=0
FALLBACK=0
FILL_ARGS=0
FILE=""
GH="${TWOW_GH:-gh}"

usage() { sed -n '6,7p' "$0" | sed 's/^# *//' >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --offline) OFFLINE=1 ;;
        --fallback-tag) FALLBACK=1 ;;
        --fill-args) FILL_ARGS=1 ;;
        --repo) REPO="${2:?--repo needs OWNER/REPO}"; shift ;;
        -h|--help) usage ;;
        -*) echo "unknown argument: $1" >&2; usage ;;
        *) [ -z "$FILE" ] || usage; FILE="$1" ;;
    esac
    shift
done
[ -n "$FILE" ] || usage
[ "$OFFLINE" -eq 0 ] || [ "$FILL_ARGS" -eq 0 ] || { echo "release-digest: --fill-args fills a deploy override and needs the online verification" >&2; exit 2; }
[ -f "$FILE" ] || { echo "release-digest: $FILE not found" >&2; exit 2; }

say() { echo "release-digest: $*" >&2; }
no() { say "NOT RELEASABLE: $*"; exit 3; }

# A scalar of the flat publish-digest.json schema: "key": "string" | true |
# false | null | number. Prints the string without quotes, or the literal.
jget() {
    grep -oE "\"$1\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|true|false|null|-?[0-9]+)" "$FILE" \
        | head -1 | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*//; s/^"(.*)"$/\1/'
}

digest=$(jget digest)
repo_sha=$(jget repo_sha)
core_sha=$(jget core_sha)
image=$(jget image)
workflow=$(jget workflow)
source=$(jget source)

[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { say "digest '$digest' is not sha256:<64 hex>"; exit 2; }
[[ "$repo_sha" =~ ^[0-9a-f]{40}$ ]] || { say "repo_sha '$repo_sha' is not 40 hex"; exit 2; }
[[ "$core_sha" =~ ^[0-9a-f]{40}$ ]] || { say "core_sha '$core_sha' is not 40 hex"; exit 2; }
owner_lc=$(printf '%s' "${REPO%%/*}" | tr '[:upper:]' '[:lower:]')
[ "$image" = "ghcr.io/$owner_lc/mangosd" ] || { say "image '$image' is not ghcr.io/$owner_lc/mangosd"; exit 2; }

promote_wf="$REPO/.github/workflows/promote.yml"
publish_wf="$REPO/.github/workflows/publish.yml"
built="$repo_sha"
case "$workflow" in
    "$promote_wf@refs/heads/main")
        case "$source" in
            promoted) ;;
            reused) no "B5a reuse of the image promoted for $(jget reused_from); deploy that commit's publish-digest.json (same digest)" ;;
            *) say "promote.yml record with source '$source'"; exit 2 ;;
        esac
        signer="$promote_wf"; source_ref=refs/heads/main ;;
    "$publish_wf@refs/tags/v"*)
        case "$source" in
            retagged)
                built=$(jget reused_from)
                [[ "$built" =~ ^[0-9a-f]{40}$ ]] || { say "retagged record without reused_from"; exit 2; }
                signer="$promote_wf"; source_ref=refs/heads/main ;;
            from-source)
                [ "$FALLBACK" -eq 1 ] || no "from-source build of ${workflow#*@} - the fallback needs --fallback-tag"
                signer="$publish_wf"; source_ref="${workflow#*@}" ;;
            *) say "publish.yml tag record with source '$source'"; exit 2 ;;
        esac ;;
    *) no "signer '$workflow' is not promote.yml on main or publish.yml on a v* tag" ;;
esac

# ------------------------------------------------------------ release rule
tree_identical=$(jget tree_identical)
pin_pr_run_id=$(jget pin_pr_run_id)
if [ "$OFFLINE" -eq 1 ]; then
    main_bt=$(jget main_build_test)
    main_smoke=$(jget main_smoke)
    pin_pr_smoke=$(jget pin_pr_smoke)
else
    # The ci push run of the built commit on main, newest first.
    run=$("$GH" api "repos/$REPO/actions/workflows/ci.yml/runs?event=push&branch=main&head_sha=$built&per_page=100" \
        --jq '[.workflow_runs[] | select(.status == "completed")] | sort_by(.run_number) | last // empty | "\(.id) \(.conclusion)"') \
        || { say "cannot list ci runs for $built"; exit 5; }
    [ -n "$run" ] || no "no completed ci push run on main for $built"
    run_id=${run%% *}
    jobs=$("$GH" api "repos/$REPO/actions/runs/$run_id/jobs?per_page=100" \
        --jq '.jobs[] | [.name, .conclusion] | join("=")') \
        || { say "cannot read the jobs of ci run $run_id"; exit 5; }
    main_bt=$(printf '%s\n' "$jobs" | sed -n 's/^build + test=//p' | head -1)
    main_smoke=$(printf '%s\n' "$jobs" | sed -n 's/^compose up + smoke=//p' | head -1)
    pin_pr_smoke=none
    if [[ "$pin_pr_run_id" =~ ^[0-9]+$ ]]; then
        pjobs=$("$GH" api "repos/$REPO/actions/runs/$pin_pr_run_id/jobs?per_page=100" \
            --jq '.jobs[] | [.name, .conclusion] | join("=")') \
            || { say "cannot read the jobs of pin PR run $pin_pr_run_id"; exit 5; }
        pin_pr_smoke=$(printf '%s\n' "$pjobs" | sed -n 's/^compose up + smoke=//p' | head -1)
    fi
    say "ci run $run_id for $built: build + test ${main_bt:-absent}, smoke ${main_smoke:-absent}"
fi
say "tree_identical=${tree_identical:-null} pin_pr_smoke=${pin_pr_smoke:-none} (pin PR run ${pin_pr_run_id:-none})"

[ "$main_bt" = success ] || no "main build + test is '${main_bt:-absent}', not success"
if [ "$tree_identical" = true ] && [ "$pin_pr_smoke" = success ]; then
    say "rule: build + test green, tree identical to the pin PR and its smoke green"
elif [ "$main_smoke" = success ]; then
    say "rule: build + test green, main smoke green"
else
    no "neither (tree identical + pin PR smoke green) nor main smoke green (tree_identical=${tree_identical:-null}, pin_pr_smoke=${pin_pr_smoke:-none}, main_smoke=${main_smoke:-absent})"
fi

# ------------------------------------------------------------ attestation
if [ "$OFFLINE" -eq 1 ]; then
    say "OFFLINE: attestation not verified - not a deploy decision"
else
    "$GH" attestation verify "oci://$image@$digest" \
        --repo "$REPO" \
        --signer-workflow "$signer" \
        --source-ref "$source_ref" \
        --deny-self-hosted-runners >&2 \
        || { say "attestation verification FAILED for $image@$digest (signer $signer, $source_ref)"; exit 4; }
fi

say "after the pull: docker image inspect --format '{{index .Config.Labels \"org.opencontainers.image.revision\"}}' $image@$digest  -> must print $built"
if [ "$FILL_ARGS" -eq 1 ]; then
    echo "${repo_sha:0:8} ${core_sha:0:8} $digest"
else
    echo "DIGEST=$digest"
    echo "REPO_SHA=$repo_sha"
    echo "CORE_SHA=$core_sha"
    echo "SIGNER=$signer"
    echo "SOURCE_REF=$source_ref"
    [ "$OFFLINE" -eq 1 ] && echo "RELEASE=OK_OFFLINE_UNVERIFIED" || echo "RELEASE=OK"
fi
