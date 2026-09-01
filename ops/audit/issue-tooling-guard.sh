#!/usr/bin/env bash
# Executable guard over the issue tooling. Fails the build if any of the four
# duplicate/no-op incidents could recur.
#
# WHY THIS FILE EXISTS
#
# The issue importer has created duplicate issues or silently failed to update
# them four separate times:
#
#   INCIDENT 1  matching an existing issue on its full TITLE, which changes
#               -> 27 duplicate issues created the day a title was reworded.
#   INCIDENT 2  `--state open` in existing_titles()
#               -> closing an issue made the next run recreate it. REF-001 and
#                  REF-002 came back as #85 and #86, hours after #79 and #80
#                  were closed as done.
#   INCIDENT 3  `--state open` in the `--update` resolver
#               -> `--update --only <ID>` silently no-opped on any CLOSED issue,
#                  printing only "could not resolve issue number". That is why
#                  #82 and #89 still carry mangled '\'' apostrophes that the
#                  documented re-sync command could never reach.
#   INCIDENT 4  ops/audit/issue-tracker-drift.sh globbing docs/issues/*.md
#               -> README.md's format-example line `id: WS10-001  # stable; ...`
#                  parsed as a real manifest entry, so the audit reported
#                  WS10-001 as unfiled. It is issue #1, and it is open.
#
# A fourteen-line comment explaining incident 2 sat DIRECTLY ABOVE the code that
# caused incident 3. Prose in the file did not prevent the recurrence. Only an
# executable check will. This is that check.
#
# Usage:
#   bash ops/audit/issue-tooling-guard.sh            # check this repository
#   bash ops/audit/issue-tooling-guard.sh --root DIR # check a copy of the tree
#
# Exits 0 when every rule holds, 1 when any rule is broken. It talks to no
# network and needs only bash, awk, sed, grep and jq.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:?--root needs a directory}"; shift ;;
        -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

IMPORTER="$ROOT/ops/issues/import-issues.sh"
DRIFT="$ROOT/ops/audit/issue-tracker-drift.sh"
FAILURES=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

command -v jq >/dev/null || { echo "jq not found; this guard needs it" >&2; exit 2; }

pass() { printf '  ok    %s\n' "$*"; }

# Every failure says WHAT broke, WHICH incident it repeats, and HOW to fix it.
# Someone hitting this in CI in six months has to be able to act on it without
# reading the git history.
fail() {
    FAILURES=$((FAILURES + 1))
    printf '\n  FAIL  %s\n' "$1"
    shift
    for line in "$@"; do printf '        %s\n' "$line"; done
    printf '\n'
}

# ------------------------------------------------------------------ helpers

# Shell source with comments removed. A `#` only starts a comment at the start
# of a line or after whitespace, so `${x%%#*}` and `$#` survive.
strip_comments() { sed -E 's/(^|[[:space:]])#.*$/\1/' "$1"; }

# Shell source with comments AND inert quoted strings removed, so that a comment
# or a message string merely MENTIONING a command is not mistaken for a call.
#
# Only strings containing no `$` are removed. A quoted span holding `$( ... )` is
# a command substitution -- real code -- and stripping it would hide the very
# call this guard counts: the one query is written `"$(gh issue list ...)"`, and
# a naive `"[^"]*"` swallows it. Erring towards keeping text costs at most a
# noisy false positive; erring the other way blinds the guard.
strip_comments_and_strings() {
    sed -E -e "s/'[^'$]*'//g" -e 's/"[^"$]*"//g' -e 's/(^|[[:space:]])#.*$/\1/' "$1"
}

# Join backslash continuations so a call split over several lines is examined
# as the single command it is (fetch_all_issues wraps its gh call over two).
join_continuations() { sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$1"; }

# Every shell script under ops/, EXCEPT this one. The guard quotes the patterns
# it forbids in its own failure messages -- a rule that cannot name what it
# forbids is a rule nobody can act on -- so scanning itself would fail on its own
# prose. The trade is that this file is not policed by itself; it is policed by
# review and by the negative tests that prove every rule fires.
shell_files() {
    find "$ROOT/ops" -name '*.sh' -type f \
         ! -name 'issue-tooling-guard.sh' | sort
}

require_file() {
    [ -f "$1" ] && return 0
    fail "missing file: ${1#"$ROOT"/}" \
         "This guard cannot check what it cannot read, and a guard that" \
         "silently skips is how all four incidents shipped." \
         "FIX: restore the file, or update ops/audit/issue-tooling-guard.sh" \
         "     if the tooling genuinely moved."
    return 1
}

echo "== issue tooling guard"
echo "   root: $ROOT"
echo

# ------------------------------------------------------- RULE 1: one query
# There must be exactly ONE `gh issue list` in the importer. Incidents 2 and 3
# were the same mistake living in two copies of the same query; a second copy is
# a second place for it to come back.
if require_file "$IMPORTER"; then
    strip_comments_and_strings "$IMPORTER" > "$TMP/importer.code"
    calls="$(grep -c 'gh issue list' "$TMP/importer.code" || true)"
    mentions="$(grep -c 'gh issue list' "$IMPORTER" || true)"
    if [ "$calls" -eq 1 ]; then
        pass "import-issues.sh has exactly 1 real \`gh issue list\` ($mentions incl. comments)"
    elif [ "$calls" -gt 1 ]; then
        fail "import-issues.sh contains $calls \`gh issue list\` calls; there must be exactly 1." \
             "REPEATS: incidents 2 and 3. Those were ONE bug (\`--state open\`)" \
             "         living in two copies of the same query -- existing_titles()" \
             "         and the --update resolver. Fixing one copy left the other." \
             "         Duplicates got created; --update silently no-opped." \
             "FIX: route the new lookup through fetch_all_issues(), which is the" \
             "     single point of truth for what issues exist. Do not add a" \
             "     second query. Offending lines:" \
             "$(grep -n 'gh issue list' "$TMP/importer.code" | sed 's/^/       /')"
    else
        fail "import-issues.sh contains NO \`gh issue list\` call." \
             "REPEATS: nothing yet -- but this guard now proves nothing, and an" \
             "         unwatched guard is how incidents 2, 3 and 4 shipped." \
             "FIX: if the lookup moved, point this rule at its new home."
    fi
fi

# ------------------------------------------------- RULE 2: no --state open
# `--state open` anywhere in the issue tooling is the exact text of incidents
# 2 and 3.
open_hits=""
while IFS= read -r f; do
    case "$f" in
        "$ROOT"/ops/issues/*|"$ROOT"/ops/audit/*) ;;
        *) continue ;;
    esac
    hit="$(strip_comments "$f" | grep -nE -- '--state[ =]+open' || true)"
    [ -z "$hit" ] || open_hits="$open_hits
${f#"$ROOT"/}:$hit"
done < <(shell_files)

if [ -z "$open_hits" ]; then
    pass "no \`--state open\` on any code line under ops/issues/ or ops/audit/"
else
    fail "\`--state open\` appears on a code line under ops/issues/ or ops/audit/." \
         "REPEATS: incident 2 -- \`--state open\` in existing_titles() meant a" \
         "         closed issue looked like it had never been filed, so the next" \
         "         run created it again. REF-001 and REF-002 came back as #85" \
         "         and #86 hours after #79 and #80 were closed as done." \
         "REPEATS: incident 3 -- the same flag in the --update resolver made" \
         "         \`--update --only <ID>\` a silent no-op on every CLOSED issue." \
         "         #82 and #89 still carry mangled apostrophes because of it." \
         "FIX: use --state all. Editing a closed issue does not reopen it, and" \
         "     an issue you cannot see is an issue you will recreate. Filter for" \
         "     open-ness AFTER the query if you need it (resolve_issue_number" \
         "     prefers OPEN, then the lowest number)." \
         "Offending lines:" \
         "$(printf '%s' "$open_hits" | sed '/^$/d;s/^/       /')"
fi

# ------------------------------------------- RULE 3: every list is --state all
# Anywhere under ops/, not just the two directories above.
missing_all=""
while IFS= read -r f; do
    join_continuations "$f" > "$TMP/joined"
    hit="$(strip_comments "$TMP/joined" \
           | grep -nE 'gh[[:space:]]+issue[[:space:]]+list' \
           | grep -v -- '--state[ =]\+all' || true)"
    [ -z "$hit" ] || missing_all="$missing_all
${f#"$ROOT"/}: $hit"
done < <(shell_files)

if [ -z "$missing_all" ]; then
    pass "every \`gh issue list\` under ops/ passes --state all"
else
    fail "a \`gh issue list\` under ops/ does not pass --state all." \
         "REPEATS: incidents 2 and 3. gh defaults to open issues. A list that" \
         "         omits closed ones makes existing issues look missing, which" \
         "         is precisely how 27 duplicates and #85/#86 were created, and" \
         "         how --update learned to no-op instead of failing loudly." \
         "FIX: add --state all to the query and, if you need only open issues," \
         "     filter afterwards." \
         "Offending commands (continuations joined, so line numbers are" \
         "approximate for wrapped calls):" \
         "$(printf '%s' "$missing_all" | sed '/^$/d;s/^/       /')"
fi

# --------------------------------------- RULE 4: the truncation abort exists
# fetch_all_issues must refuse to answer from a list that hit --limit. A
# truncated list makes existing issues look missing, which is how duplicates get
# created. This rule does not grep for the guard: it EXERCISES it.
#
# The lookup functions are lifted out of the importer and run against a stub
# `gh`, so what is tested is the real code, not a copy of it.
lookup_harness() {
    local out="$1"
    {
        echo 'set -uo pipefail'
        echo 'REPO="fixture/repo"'
        echo 'gh() { cat "$GH_FIXTURE"; }'
        awk '
            /^ISSUE_CACHE=/ { p = 1 }
            p { print }
            /^resolve_issue_number\(\)/ { r = 1 }
            r && /^}/ { exit }
        ' "$IMPORTER"
        echo 'case "${1:-}" in'
        echo '  resolve) resolve_issue_number "$2" ;;'
        echo '  titles)  existing_titles ;;'
        echo '  fetch)   fetch_all_issues >/dev/null ;;'
        echo 'esac'
    } > "$out"
    for fn in fetch_all_issues existing_titles resolve_issue_number; do
        grep -q "^$fn()" "$out" || return 1
    done
    return 0
}

harness="$TMP/lookup.sh"
if [ -f "$IMPORTER" ] && lookup_harness "$harness"; then
    limit="$(sed -nE 's/^ISSUE_LIMIT=([0-9]+).*/\1/p' "$IMPORTER" | head -1)"
    if [ -z "$limit" ]; then
        fail "ISSUE_LIMIT is gone from import-issues.sh." \
             "REPEATS: the duplicate-creation family. Without a known limit" \
             "         there is nothing to compare the result count against," \
             "         so a truncated list passes as complete." \
             "FIX: keep \`ISSUE_LIMIT=<n>\` and the abort in fetch_all_issues."
    else
        # A full page: the result count reaches the limit, so the list may be
        # truncated and every issue past it looks unfiled.
        jq -nc --argjson n "$limit" \
           '[range($n) | {number: (.+1), title: "REF-001: t", state: "CLOSED"}]' \
           > "$TMP/full.json"
        if GH_FIXTURE="$TMP/full.json" bash "$harness" fetch >"$TMP/trunc.out" 2>&1; then
            fail "fetch_all_issues returned a list that had hit ISSUE_LIMIT ($limit) instead of aborting." \
                 "REPEATS: the root cause of every duplicate incident. A" \
                 "         truncated list makes an existing issue look missing," \
                 "         and the importer then creates it a second time -- 27" \
                 "         times over, once." \
                 "FIX: restore the abort in fetch_all_issues:" \
                 "       if [ \"\$n\" -ge \"\$ISSUE_LIMIT\" ]; then ... exit 1; fi" \
                 "     Paginate or raise the limit rather than guessing."
        elif grep -q "$limit" "$TMP/trunc.out"; then
            pass "fetch_all_issues aborts on a list that hit ISSUE_LIMIT ($limit) -- exercised, not grepped"
        else
            fail "fetch_all_issues failed on a full page, but not with the truncation message." \
                 "REPEATS: incident-class 'silent failure'. It exited non-zero" \
                 "         without saying the list was truncated, so whoever hits" \
                 "         it in CI cannot tell a truncated list from a broken jq." \
                 "FIX: keep the explicit FATAL message naming ISSUE_LIMIT." \
                 "Got: $(head -3 "$TMP/trunc.out")"
        fi

        # --------------------------------------- RULE 4b: the resolver itself
        # resolve_issue_number is the function that must never regress. Fixture:
        # an OPEN original, a CLOSED lower-numbered duplicate, a reworded title,
        # and a near-miss id that must NOT match.
        cat > "$TMP/resolver.json" <<'JSON'
[
  {"number": 40, "title": "REF-001: an old wording of this task", "state": "CLOSED"},
  {"number": 85, "title": "REF-001: a completely reworded title", "state": "OPEN"},
  {"number": 91, "title": "REF-0011: a different issue entirely", "state": "OPEN"},
  {"number": 99, "title": "REF-002: later duplicate", "state": "OPEN"},
  {"number": 12, "title": "REF-002: the original", "state": "OPEN"},
  {"number": 89, "title": "REF-009: closed, and still needs editing", "state": "CLOSED"}
]
JSON
        expect() { # expect <id> <want> <why>
            local got
            got="$(GH_FIXTURE="$TMP/resolver.json" bash "$harness" resolve "$1" 2>&1)"
            if [ "$got" = "$2" ]; then
                pass "resolve_issue_number $1 -> ${2:-<empty>}  ($3)"
            else
                fail "resolve_issue_number $1 returned '${got:-<empty>}', expected '${2:-<empty>}'." \
                     "WHY THIS CASE EXISTS: $3" \
                     "REPEATS: incident 1 (matched on the changing TITLE -> 27" \
                     "         duplicates) and incident 3 (could not see CLOSED" \
                     "         issues, so --update silently did nothing)." \
                     "FIX: resolve on the stable id prefix over a --state all" \
                     "     list, preferring OPEN and then the lowest number."
            fi
        }
        expect REF-001 85 "an OPEN issue wins over a CLOSED lower-numbered duplicate"
        expect REF-002 12 "among OPEN issues the lowest number wins: the original, not the duplicate"
        expect REF-009 89 "a CLOSED issue still resolves, so --update can reach it"
        expect REF-0 "" "a partial id must not match; the separator is part of the key"

        titles="$(GH_FIXTURE="$TMP/resolver.json" bash "$harness" titles 2>&1)"
        if printf '%s\n' "$titles" | grep -q '^REF-009: '; then
            pass "existing_titles includes CLOSED issues, so a closed issue is not refiled"
        else
            fail "existing_titles did not return the CLOSED fixture issue." \
                 "REPEATS: incident 2 exactly. A closed issue that is invisible" \
                 "         to the existence check gets created again -- REF-001" \
                 "         and REF-002 came back as #85 and #86 that way." \
                 "FIX: existing_titles must read the same --state all list as" \
                 "     everything else (fetch_all_issues)."
        fi
    fi
elif [ -f "$IMPORTER" ]; then
    fail "could not lift fetch_all_issues / existing_titles / resolve_issue_number out of import-issues.sh." \
         "REPEATS: potentially all four -- the behavioural half of this guard" \
         "         just stopped running, and an unexercised guard is worthless." \
         "FIX: either keep those three functions at top level in the importer," \
         "     or update lookup_harness() in this file to match the new shape." \
         "     Do NOT delete the rule."
fi

# ------------------------------------------ RULE 5: the drift script's glob
if require_file "$DRIFT"; then
    if grep -q "docs/issues/\[0-9\]\*\.md" "$DRIFT"; then
        pass "issue-tracker-drift.sh globs docs/issues/[0-9]*.md"
    else
        fail "issue-tracker-drift.sh does not glob docs/issues/[0-9]*.md." \
             "REPEATS: incident 4 -- the glob was docs/issues/*.md, so README.md" \
             "         was read as a manifest. Its format-example line" \
             "         \`id: WS10-001  # stable; ...\` parsed as a real entry whose" \
             "         id carried the trailing comment, overwrote the genuine" \
             "         WS10-001, and the audit reported it as unfiled. WS10-001" \
             "         is issue #1, and it is open." \
             "FIX: glob docs/issues/[0-9]*.md -- the numbered manifests only," \
             "     which is exactly what import-issues.sh reads. Current glob(s):" \
             "$(grep -n "docs/issues/[^']*\.md" "$DRIFT" | sed 's/^/       /')"
    fi
    if grep -qE "glob\.glob\([^)]*docs/issues/\*\.md" "$DRIFT"; then
        fail "issue-tracker-drift.sh still globs docs/issues/*.md somewhere." \
             "REPEATS: incident 4, as above -- README.md gets parsed as a" \
             "         manifest and the audit invents drift." \
             "FIX: use docs/issues/[0-9]*.md."
    fi
fi

# ------------------------------------------------------------------ verdict
echo
if [ "$FAILURES" -eq 0 ]; then
    echo "issue tooling guard: PASS"
    exit 0
fi
echo "issue tooling guard: FAIL ($FAILURES rule(s) broken)"
echo
echo "These rules exist because the importer created duplicates or silently"
echo "no-opped four times. A comment explaining one of those incidents sat"
echo "directly above the code that caused the next one. Fix the code, not"
echo "this guard."
exit 1
