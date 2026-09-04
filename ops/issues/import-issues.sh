#!/usr/bin/env bash
# Create GitHub issues from the manifests in docs/issues/.
#
# Idempotent by construction: every issue title is prefixed with the manifest id,
# and an id that already has an issue is skipped rather than updated or
# duplicated. A half-finished run is repaired by running it again.
#
# Dry run is the default. Pass --apply to actually create anything.
#
#   ops/issues/import-issues.sh                 # show what would happen
#   ops/issues/import-issues.sh --apply         # create labels, milestones, issues
#   ops/issues/import-issues.sh --apply --only WS10-001
#
# Concurrency is deliberately low. GitHub applies secondary rate limits to
# content creation, and a burst of 40 parallel creates gets throttled or
# partially rejected -- which is the worst possible outcome for an import.
set -euo pipefail

REPO="${TWOW_ISSUE_REPO:-Cilverkrow/twow-repo}"
MANIFEST_DIR="${TWOW_MANIFEST_DIR:-docs/issues}"
APPLY=0
UPDATE=0
ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --update) UPDATE=1 ;;
        --only) ONLY="${2:-}"; shift ;;
        --repo) REPO="${2:-}"; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated" >&2; exit 1; }

say() { printf '%s\n' "$*"; }
run() {
    if [ "$APPLY" -eq 1 ]; then "$@"; else say "  DRY-RUN: $*"; fi
}

# ---------------------------------------------------------------- labels
# Workstream labels mirror the collaboration hub (WS-00..WS-80) so the tracker
# and the governance model stay addressable by the same key.
ensure_labels() {
    say "== labels"
    set -- \
        "ws-00:0e8a16:Project steering and workspace" \
        "ws-10:0e8a16:SSC analysis and development" \
        "ws-20:0e8a16:Database and migrations" \
        "ws-30:0e8a16:Server configuration" \
        "ws-40:0e8a16:Deployment and scripts" \
        "ws-50:0e8a16:Build and server operation" \
        "ws-60:0e8a16:Reference server and backups" \
        "ws-70:0e8a16:Bot personalities" \
        "ws-80:0e8a16:Documentation and decisions" \
        "p0:b60205:Blocks architecture or release" \
        "p1:d93f0b:Correctness and scale" \
        "p2:fbca04:Maintainability and provenance" \
        "refactor:1d76db:Part of the OT-025 restructuring" \
        "deferred-architecture:5319e7:Designed, deliberately not in the refactor" \
        "adr:c5def5:Needs or records an architecture decision" \
        "from-runbook:bfd4f2:Recovered from runbook evidence"
    for spec in "$@"; do
        name="${spec%%:*}"; rest="${spec#*:}"
        colour="${rest%%:*}"; desc="${rest#*:}"
        if gh label list --repo "$REPO" --limit 200 | cut -f1 | grep -qx "$name"; then
            say "  = $name"
        else
            say "  + $name"
            run gh label create "$name" --repo "$REPO" --color "$colour" --description "$desc"
        fi
    done
}

# ---------------------------------------------------------------- milestones
ensure_milestones() {
    say "== milestones"
    existing="$(gh api "repos/$REPO/milestones?state=all" --jq '.[].title' 2>/dev/null || true)"
    for m in "Phase 0 - foundations" \
             "Phase 1 - one-command run" \
             "Phase 2 - upstream split" \
             "Phase 3 - feature modules" \
             "Deferred"; do
        if printf '%s\n' "$existing" | grep -qxF "$m"; then
            say "  = $m"
        else
            say "  + $m"
            run gh api "repos/$REPO/milestones" -f title="$m" >/dev/null
        fi
    done
}

# ---------------------------------------------------------------- issues
# The manifest is a sequence of YAML-ish blocks delimited by '---'. Parsing it
# with awk keeps this script dependency-free; the format is deliberately simple
# enough that this is safe (no nested structures, one 'body: |' block last).
# ---------------------------------------------------------------------------
# THE SINGLE POINT OF TRUTH FOR "WHAT ISSUES EXIST".
#
# Everything that asks GitHub what exists goes through fetch_all_issues. There
# is exactly ONE `gh issue list` in this file, and
# ops/audit/issue-tooling-guard.sh fails the build if a second one appears.
#
# That guard exists because this bug has now shipped four times, and the last
# two were the same mistake living in two copies of the same query:
#
#   * matching on the full TITLE, which changes   -> 27 duplicates created
#   * `--state open` in existing_titles()         -> REF-001 and REF-002 were
#                                                    recreated as #85 and #86,
#                                                    hours after #79 and #80
#                                                    were closed as done
#   * `--state open` in the --update resolver     -> `--update --only <ID>`
#                                                    silently no-opped on every
#                                                    closed issue, so #82 and
#                                                    #89 kept mangled quotes the
#                                                    documented re-sync could
#                                                    never reach
#
# The comment explaining the second one sat directly above the third and did
# not prevent it. Prose does not stop this. One query and a guard do.
# ---------------------------------------------------------------------------
ISSUE_CACHE=""
ISSUE_LIMIT=1000

fetch_all_issues() {
    if [ -n "$ISSUE_CACHE" ]; then
        printf '%s' "$ISSUE_CACHE"
        return 0
    fi
    ISSUE_CACHE="$(gh issue list --repo "$REPO" --state all \
                    --limit "$ISSUE_LIMIT" --json number,title,state)"
    n="$(printf '%s' "$ISSUE_CACHE" | jq 'length')"
    # A truncated list makes an existing issue look missing, which is exactly
    # how duplicates get created. Refuse to guess.
    if [ "$n" -ge "$ISSUE_LIMIT" ]; then
        echo "FATAL: issue list hit the $ISSUE_LIMIT limit ($n returned)." >&2
        echo "       A truncated list makes existing issues look missing, and" >&2
        echo "       this script would recreate them. Paginate or raise the" >&2
        echo "       limit before running again." >&2
        exit 1
    fi
    printf '%s' "$ISSUE_CACHE"
}

existing_titles() {
    fetch_all_issues | jq -r '.[].title'
}

# Resolve a manifest id to an issue number. Prefers an OPEN issue, then the
# lowest number: the original, never an accidental duplicate. Matches on the id
# prefix, which is stable -- not on the title, which is not.
resolve_issue_number() {
    fetch_all_issues | jq -r --arg id "$1" '
        .[]
        | select(.title | startswith($id + ": "))
        | "\(if .state == "OPEN" then 0 else 1 end) \(.number)"' \
      | sort -k1,1n -k2,2n | head -1 | awk '{print $2}'
}

import_file() {
    file="$1"
    say "== $file"
    # The third label records where the item came from, which is what tells a
    # reader whether it is recovered history or forward design.
    case "$(basename "$file")" in
        2*) origin_label="from-runbook"; milestone="" ;;
        30-deferred*) origin_label="deferred-architecture"; milestone="Deferred" ;;
        *) origin_label="refactor"; milestone="" ;;
    esac
    awk '
        /^---$/ { if (id != "") emit(); reset(); inbody=0; next }
        # An id line while a body is still open means the previous entry has no
        # closing ---. Silently, awk would then overwrite the id, keep appending to
        # the same body, and emit ONE record carrying two entries concatenated --
        # dropping the first outright. That happened to ARCH-003, which vanished
        # from the tracker while ARCH-004 was created holding both bodies. Nothing
        # reported it. Refuse instead.
        /^id: / && inbody==1 { print "MALFORMED " FILENAME ":" FNR ": " $0 " begins while the body of \"" id "\" is still open (missing --- separator)" > "/dev/stderr"; exit 3 }
        /^id: / { id=substr($0,5); next }
        /^title: / { title=substr($0,8); next }
        /^workstream: / { ws=tolower(substr($0,13)); next }
        /^priority: / { prio=substr($0,11); next }
        /^existing_ot: / { ot=substr($0,14); next }
        /^source: / { src=substr($0,9); next }
        /^superseded_by: / { next }
        # status: retires an entry. open (default) | done | obsolete. A non-open
        # entry is never created, and --update closes an existing issue instead
        # of rewriting it. Without this a triage decision evaporates on the next
        # run, which is how solved work keeps coming back.
        /^status: / { status=substr($0,9); next }
        /^status_note: / { note=substr($0,14); next }
        /^body: \|$/ { inbody=1; next }
        inbody==1 { sub(/^  /,""); body = body $0 "\n"; next }
        END { if (id != "") emit() }
        function reset() { id=""; title=""; ws=""; prio=""; ot=""; src=""; body=""; status=""; note="" }
        function emit() {
            # Deliberately no shell-escaping of the body here. It travels through a
            # variable and is passed as --body "$full_body" -- inside double quotes,
            # where single quotes need no escaping at all. Nothing ever consumed it, so
            # the escape sequence simply landed in the issue text: every apostrophe in
            # 32 of 117 imported issues rendered as a four-character mess on GitHub.
            printf "%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1e", id, title, ws, prio, ot, src, status, note, body
        }
    ' "$file" | while IFS=$'\x1f' read -r -d $'\x1e' id title ws prio ot src status note body; do
        [ -n "${id:-}" ] || continue
        [ -z "${ONLY:-}" ] || [ "${ONLY}" = "$id" ] || continue

        full_title="$id: $title"
        # Match on the id prefix, never the full title. Titles get reworded; the
        # id is the stable key. Matching on the full title silently creates a
        # duplicate the moment a title is improved -- that happened once and
        # produced 27 duplicate issues.
        exists=0
        printf '%s\n' "$KNOWN_TITLES" | grep -q "^${id}: " && exists=1
        # A retired entry never becomes an issue, and an existing one is closed
        # rather than rewritten. This is what makes a triage decision stick: without
        # it, deciding "we are not doing this" is invisible to the importer and the
        # entry is presented as live work again on the next run.
        case "${status:-open}" in
            done|obsolete)
                if [ "$exists" -eq 0 ]; then
                    say "  . $id (status=${status}, not created)"
                    continue
                fi
                if [ "$UPDATE" -eq 1 ]; then
                    say "  x $id (status=${status}, closing)"
                    if [ "$APPLY" -eq 1 ]; then
                        num="$(resolve_issue_number "$id")"
                        if [ -n "$num" ]; then
                            reason="${note:-retired in the manifest as ${status}}"
                            gh issue close "$num" --repo "$REPO" \
                                --comment "Closed as ${status}: ${reason}" >/dev/null 2>&1 \
                                || say "    ! could not close #$num"
                            sleep 1
                        else
                            say "    ! could not resolve issue number for $id"
                        fi
                    fi
                fi
                continue
                ;;
        esac
        if [ "$exists" -eq 1 ] && [ "$UPDATE" -eq 0 ]; then
            say "  = $id (exists)"
            continue
        fi

        # Evidence path and cross-reference belong in the issue, not just the
        # manifest -- an issue that cannot be traced back is not actionable.
        full_body="$body"
        full_body="$full_body
---
**Evidence:** \`$src\`"
        [ "$ot" = "none" ] || full_body="$full_body
**Tracked in TODOS.md as:** $ot"
        full_body="$full_body
**Manifest:** \`$file\` (id \`$id\`) - regenerate with \`ops/issues/import-issues.sh\`"

        labels="$ws,$prio,$origin_label"

        # --update rewrites the body of an issue that already exists, so the
        # manifest stays the single source of truth after an edit.
        if [ "$exists" -eq 1 ]; then
            say "  ~ $full_title (update body)"
            if [ "$APPLY" -eq 1 ]; then
                # Prefer an OPEN issue, then the lowest number: the original, not any
                # accidental duplicate.
                #
                # This read "--state open", which meant `--update --only <ID>` silently
                # no-opped on a CLOSED issue and printed only "could not resolve issue
                # number". That is how two bodies kept their mangled apostrophes long
                # after the importer bug that wrote them was fixed: both issues were
                # closed, so the documented re-sync could never reach them.
                #
                # Editing a closed issue does not reopen it, so --state all is safe.
                num="$(resolve_issue_number "$id")"
                if [ -n "$num" ]; then
                    gh issue edit "$num" --repo "$REPO" \
                        --title "$full_title" --body "$full_body" >/dev/null
                    sleep 1
                else
                    say "    ! could not resolve issue number for $id"
                fi
            fi
            continue
        fi

        say "  + $full_title  [$labels]"
        if [ "$APPLY" -eq 1 ]; then
            if [ -n "$milestone" ]; then
                gh issue create --repo "$REPO" \
                    --title "$full_title" --body "$full_body" \
                    --label "$labels" --milestone "$milestone" >/dev/null
            else
                gh issue create --repo "$REPO" \
                    --title "$full_title" --body "$full_body" \
                    --label "$labels" >/dev/null
            fi
            # Stay well under the secondary rate limit for content creation.
            sleep 2
        fi
    done
}

ensure_labels
ensure_milestones

KNOWN_TITLES="$(existing_titles)"
export KNOWN_TITLES ONLY APPLY UPDATE REPO

for f in "$MANIFEST_DIR"/[0-9]*.md; do
    [ -e "$f" ] || continue
    import_file "$f"
done

if [ "$APPLY" -eq 0 ]; then
    say ""
    say "Dry run only. Re-run with --apply to create these."
fi
