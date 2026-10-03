#!/usr/bin/env bash
# Runner and trigger policy for GitHub Actions workflows (#486, plan B1).
#
#   test-workflow-runner-policy.sh [--root DIR] [--allowlist FILE] [--self-test]
#
# WHY. Both repositories are public. A job is handed to any runner whose labels
# match, and a pull request's workflow file comes from the PR's own merge ref, so
# the PR author chooses `runs-on`. This test pins the merged state of every
# workflow to GitHub-hosted runners and keeps the triggers that run foreign code
# with base-repository privileges out. It protects the merged state only: a PR
# can still edit its own copy of a workflow, which is why the rulesets and
# CODEOWNERS of B0 are its precondition (docs/runbooks/github-settings-486.md).
#
# RULES. Comment lines (`^\s*#`) and the bodies of block scalars (`run: |`,
# `description: >-`, ...) are removed first, so prose and shell code that merely
# mention a label or a trigger are never findings. Keys are matched as YAML
# spells them (quoted, blanks before the colon, indentless sequences); forms a
# line-based reader cannot follow fail closed instead of passing silently:
# flow-mapping jobs, `runs-on` outside a block-style key, block-scalar
# `runs-on`, YAML complex keys (`? key`).
#
#   R1  A workflow triggered by `pull_request`, `pull_request_review` or
#       `pull_request_review_comment` (all run in fork-PR context) may not name
#       `self-hosted`, or any label that only the self-hosted allowlist admits,
#       in `runs-on:` or in its `labels:` entries, nor call a reusable workflow
#       from another repository (job-level `uses: owner/repo/...@ref`, whose
#       runs-on picks this repository's runners). `runs-on` built from `vars.`,
#       `inputs.` or `fromJSON` is forbidden in every workflow: repository
#       variables are visible to fork PRs, so one variable would move every fork
#       PR onto a self-hosted runner. A file the allowlist names with
#       `self-hosted` may not have the `workflow_call` trigger, since a callee
#       inherits its caller's event.
#   R2  `pull_request_target` and `issue_comment` are forbidden, also as bare
#       words anywhere in code (backstop for trigger spellings not parsed).
#       `workflow_run` is allowed only in files the allowlist names with
#       `workflow_run`, and those files must check `head_branch`,
#       `event == 'push'` and `head_repository.full_name` inside `if:` values
#       (trailing comments and other keys do not count).
#   R3  `runs-on` admits only the literal labels ubuntu-latest, ubuntu-24.04,
#       windows-latest and windows-2022. Expressions and runner groups are not
#       literals. `self-hosted` (with the default self-hosted labels linux, x64,
#       arm64, windows, macos) is admitted only in files the allowlist names
#       with `self-hosted`. Reusable workflows from other repositories are not
#       admitted in any workflow.
#   R4  Every workflow has a top-level `permissions:` block.
#   R5  Workflow files nested deeper than <root>/.github/workflows are reported
#       as warnings only; GitHub never runs them.
#   R6  --self-test: every ok*.yml fixture passes and every bad-*.yml fixture
#       fails with the rule named in its `# expect: Rn` header line.
#
# INTERFACE (other PRs and the twow-core copy rely on it).
#   --root DIR        repository to check. Default: two levels above this script,
#                     which is the repository root both for ops/ci/ here and for
#                     the copy at .github/policy/ in twow-core.
#   --allowlist FILE  default: <root>/ops/ci/workflow-policy-allowlist.txt.
#                     One entry per line, `#` starts a comment:
#                         workflow_run <path relative to root>
#                         self-hosted  <path relative to root>
#                     A missing file counts as empty, which is the strictest case.
#   --self-test       check the fixtures next to this script instead of a
#                     repository: <script dir>/fixtures/workflow-policy/, whose
#                     paths in allowlist.txt are relative to that directory.
#
# COPY CHECK. twow-core carries a byte-identical copy at
# .github/policy/test-workflow-runner-policy.sh. When <root>/core holds that copy
# (submodule checked out), its sha256 must equal this file's; otherwise the check
# is skipped with a notice. The core-gitlink-trust job in ci.yml runs the same
# comparison against the pinned core commit without a submodule checkout.
#
# Only bash and POSIX tools (awk, sed, grep, find, sha256sum): the Windows host
# has neither python nor node, and Ubuntu's default awk is mawk.

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
ROOT=""
ALLOWLIST=""
SELF_TEST=0

usage() { sed -n '4p' "$SCRIPT_PATH" | sed 's/^# *//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:?--root needs a directory}"; shift ;;
        --allowlist) ALLOWLIST="${2:?--allowlist needs a file}"; shift ;;
        --self-test) SELF_TEST=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

HOSTED_LABELS=" ubuntu-latest ubuntu-24.04 windows-latest windows-2022 "
SELF_HOSTED_LABELS=" self-hosted linux x64 arm64 windows macos "

# Allowlist entries of the current run, newline-separated relative paths.
ALLOW_WORKFLOW_RUN=""
ALLOW_SELF_HOSTED=""

load_allowlist() {
    local file="$1" base="$2" n=0 type path rest line
    ALLOW_WORKFLOW_RUN=""
    ALLOW_SELF_HOSTED=""
    if [ ! -f "$file" ]; then
        echo "::notice::allowlist $file not found - treated as empty"
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line="${line%%#*}"
        line="${line%$'\r'}"
        read -r type path rest <<< "$line" || true
        [ -n "${type:-}" ] || continue
        if [ -z "${path:-}" ] || [ -n "${rest:-}" ]; then
            echo "::error file=$file,line=$n::allowlist entry must be '<type> <path>'"
            return 1
        fi
        case "$type" in
            workflow_run) ALLOW_WORKFLOW_RUN="$ALLOW_WORKFLOW_RUN$path"$'\n' ;;
            self-hosted) ALLOW_SELF_HOSTED="$ALLOW_SELF_HOSTED$path"$'\n' ;;
            *) echo "::error file=$file,line=$n::unknown allowlist type '$type' (workflow_run|self-hosted)"
               return 1 ;;
        esac
        if [ ! -f "$base/$path" ]; then
            echo "::warning file=$file,line=$n::allowlist names $path, which does not exist"
        fi
    done < "$file"
}

listed() { # listed <newline list> <path>
    # Here-strings, not `printf | grep -q`: under pipefail an early-exiting
    # grep -q turns printf's SIGPIPE into a failure on large inputs.
    grep -Fqx -- "$2" <<< "$1"
}

# Emit the facts of one workflow file, one per line, tab-separated:
#   TRIGGER <name>
#   LABEL   <line> <label, lower case>
#   EXPR    <line> <expression, or why runs-on could not be read>
#   GROUP   <line> <group>
#   PERMS   <line>
#   IFEXPR  <text>      (value of an `if:` key, with continuation lines)
#   NCODE   <line> <text>  (non-comment line outside block scalars, trailing
#                          comment removed; input of the backstop greps)
#   QKEY    <line>      (YAML complex key `? ...`)
#   ROBAD   <line> <text>  (`runs-on` on a line not parsed as a runs-on key)
#   JOBUSES <line> <ref>   (job-level `uses:`, a reusable workflow)
#   JOBFLOW <line> <text>  (jobs or a job written as a flow mapping)
# Keys are matched the way YAML spells them: optionally quoted, optionally
# with blanks before the colon. Forms the parser does not understand are
# reported (fail closed), never skipped.
extract_facts() {
    awk -v q="'" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function unquote(s) {
        s = trim(s)
        f = substr(s, 1, 1); l = substr(s, length(s), 1)
        if (length(s) >= 2 && f == l && (f == "\"" || f == q)) s = substr(s, 2, length(s) - 2)
        return s
    }
    function nocomment(s) { sub(/[ \t]+#.*$/, "", s); return s }
    function keyis(s, k) { return s ~ ("^[\"" q "]?" k "[\"" q "]?[ \t]*:") }
    function value_of(s) { sub(/^[^:]*:/, "", s); return trim(nocomment(s)) }
    function emit_label(v, lno) {
        v = unquote(v)
        if (v == "") return
        rocnt++
        if (v ~ /\$[{][{]/) { print "EXPR\t" lno "\t" v; return }
        if (v ~ /^[{]/)     { print "EXPR\t" lno "\t" v; return }
        print "LABEL\t" lno "\t" tolower(v)
    }
    function emit_flow(v, lno,   n, i, parts) {
        if (v ~ /\$[{][{]/) { rocnt++; print "EXPR\t" lno "\t" v; return }
        gsub(/^\[|\]$/, "", v)
        n = split(v, parts, ",")
        for (i = 1; i <= n; i++) emit_label(parts[i], lno)
    }
    function emit_triggers(v,   n, i, parts) {
        gsub(/[\[\]]/, "", v)
        n = split(v, parts, ",")
        for (i = 1; i <= n; i++) {
            parts[i] = unquote(parts[i])
            if (parts[i] != "") print "TRIGGER\t" parts[i]
        }
    }
    function ro_close() {
        if (rocnt == 0) print "EXPR\t" roline "\truns-on without a parseable literal label"
        inro = 0
    }
    {
        line = $0
        sub(/\r$/, "", line)
        if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) next
        i = ind(line)

        # Body of a block scalar: everything indented deeper than its key line.
        if (inblock) {
            if (i > blockind) {
                print "BODY\t" line
                if (ifblock) print "IFEXPR\t" trim(nocomment(line))
                next
            }
            inblock = 0; ifblock = 0
        }

        nline = nocomment(line)
        print "CODE\t" line
        print "NCODE\t" NR "\t" nline

        body = trim(line)
        item = body
        sub(/^-[ \t]*/, "", item)
        keycol = i + length(body) - length(item)

        # Continuation of a multi-line flow sequence `on: [push,`.
        if (inonflow) {
            onacc = onacc "," trim(nline)
            if (index(nline, "]")) { emit_triggers(onacc); inonflow = 0 }
        }

        # Complex keys cannot be mapped to a rule; never legitimate here.
        if (body ~ /^\?([ \t]|$)/ || item ~ /^\?([ \t]|$)/) print "QKEY\t" NR

        # Leaving the on:, runs-on: or if: block. An indentless sequence
        # (`runs-on:` then `- label` at the same indent) stays inside.
        if (inon && i == 0) inon = 0
        if (inro && (i < roind || (i == roind && body !~ /^-/))) ro_close()
        if (inif && i <= ifind) inif = 0
        if (inif) print "IFEXPR\t" trim(nline)

        if (i == 0 && keyis(body, "(on|true)")) {
            v = value_of(body)
            if (v ~ /^[{]/) print "TRIGGER\t{flow-mapping}"
            else if (v ~ /^\[/ && index(v, "]") == 0) { inonflow = 1; onacc = v }
            else if (v != "") emit_triggers(v)
            else { inon = 1; onchild = -1 }
        } else if (inon) {
            if (onchild < 0) onchild = i
            if (i == onchild) {
                name = item
                sub(/:.*$/, "", name)
                name = unquote(name)
                if (name != "") print "TRIGGER\t" name
            }
        }

        if (i == 0 && keyis(body, "permissions")) print "PERMS\t" NR

        # jobs: job keys at the first child indent, job-level keys one deeper.
        if (i == 0) {
            injobs = keyis(body, "jobs")
            if (injobs) {
                jobind = -1
                v = value_of(body)
                if (v != "") print "JOBFLOW\t" NR "\t" v
            }
        } else if (injobs) {
            if (jobind < 0) jobind = i
            if (i == jobind) {
                jobbody = -1
                v = value_of(body)
                if (v != "" && v !~ /^&[^ \t]*$/) print "JOBFLOW\t" NR "\t" v
            } else if (i > jobind) {
                if (jobbody < 0) jobbody = i
                if (i == jobbody && body !~ /^-/ && keyis(item, "uses"))
                    print "JOBUSES\t" NR "\t" unquote(value_of(item))
            }
        }

        if (keyis(item, "if")) {
            v = value_of(item)
            if (v !~ /^[|>]/) { print "IFEXPR\t" v; inif = 1; ifind = keycol }
        }

        handled = 0
        if (keyis(item, "runs-on")) {
            handled = 1
            if (inro) ro_close()
            v = value_of(item)
            rocnt = 0; roline = NR
            if (v == "") { inro = 1; roind = i }
            else if (v ~ /^[|>]/) print "EXPR\t" NR "\truns-on as a block scalar cannot be checked"
            else {
                if (v ~ /^\[/) emit_flow(v, NR); else emit_label(v, NR)
                if (rocnt == 0) print "EXPR\t" NR "\truns-on without a parseable literal label"
            }
        } else if (inro) {
            if (body ~ /^-/) emit_label(nocomment(item), NR)
            else if (keyis(item, "labels")) {
                v = value_of(item)
                if (v ~ /^\[/) emit_flow(v, NR); else if (v != "") emit_label(v, NR)
            } else if (keyis(item, "group")) { rocnt++; print "GROUP\t" NR "\t" value_of(item) }
            else { rocnt++; print "EXPR\t" NR "\t" body }
        }
        if (!handled && nline ~ /runs-on/) print "ROBAD\t" NR "\t" trim(nline)

        if (nline ~ /:[ \t]*[|>][-+0-9]*[ \t]*$/) {
            inblock = 1; blockind = i; ifblock = keyis(item, "if")
        }
    }
    END {
        if (inro) ro_close()
        if (inonflow) emit_triggers(onacc)
    }
    ' "$1"
}

# check_file <absolute file> <path relative to the allowlist base>
# Prints annotations; returns the number of errors (capped at 255).
check_file() {
    local file="$1" rel="$2" facts guards ncode errors=0 pr=0 trig kind lno val
    local selfhosted_ok=0 seen_forbidden=0 seen_wfrun=0 callable=0
    facts="$(extract_facts "$file")"
    # Guards count only inside `if:` values (folded or block scalars included),
    # with trailing comments removed: a comment or a name: is no guard.
    guards="$(grep -E '^IFEXPR' <<< "$facts" || true)"
    # Backstop input: code lines without comments and without block bodies.
    ncode="$(grep -E '^NCODE' <<< "$facts" | cut -f3- || true)"
    listed "$ALLOW_SELF_HOSTED" "$rel" && selfhosted_ok=1

    err() { echo "::error file=$rel${1:+,line=$1}::[$2] $3"; errors=$((errors + 1)); }

    while IFS=$'\t' read -r kind trig; do
        [ "$kind" = TRIGGER ] || continue
        case "$trig" in
            # The review events run in fork-PR context as well.
            pull_request|pull_request_review|pull_request_review_comment) pr=1 ;;
            workflow_call) callable=1 ;;
            '{flow-mapping}')
                pr=1
                err "" R2 "'on:' written as a flow mapping cannot be checked; use the block form" ;;
            pull_request_target|issue_comment)
                seen_forbidden=1
                err "" R2 "trigger '$trig' runs with base-repository privileges on foreign input and is forbidden" ;;
            workflow_run)
                seen_wfrun=1
                if ! listed "$ALLOW_WORKFLOW_RUN" "$rel"; then
                    err "" R2 "workflow_run is allowed only in files the allowlist names with 'workflow_run'"
                else
                    grep -q 'head_branch' <<< "$guards" \
                        || err "" R2 "workflow_run without a head_branch guard in an if:"
                    grep -Eq "event[[:space:]]*==[[:space:]]*'push'" <<< "$guards" \
                        || err "" R2 "workflow_run without an event == 'push' guard in an if:"
                    grep -q 'head_repository\.full_name' <<< "$guards" \
                        || err "" R2 "workflow_run without a head_repository.full_name guard in an if:"
                fi ;;
        esac
    done <<< "$facts"

    # Backstops for trigger spellings the parser may not see: the bare words
    # count wherever they stand in code (comments and block bodies excluded).
    if [ "$seen_forbidden" -eq 0 ] \
        && grep -Eq '(^|[^A-Za-z0-9_])(pull_request_target|issue_comment)([^A-Za-z0-9_]|$)' <<< "$ncode"; then
        err "" R2 "pull_request_target/issue_comment appears in code but was not parsed as a trigger; forbidden in any form"
    fi
    if [ "$seen_wfrun" -eq 0 ] && ! listed "$ALLOW_WORKFLOW_RUN" "$rel" \
        && grep -Eq '(^|[^A-Za-z0-9_])workflow_run([^A-Za-z0-9_]|$)' <<< "$ncode"; then
        err "" R2 "workflow_run appears in code of a file the allowlist does not name with 'workflow_run'"
    fi
    # A local callee inherits the caller's event, pull_request included.
    if [ "$callable" -eq 1 ] && [ "$selfhosted_ok" -eq 1 ]; then
        err "" R1 "workflow_call in a file the allowlist names with 'self-hosted': a pull_request caller would put fork code on that runner"
    fi

    while IFS=$'\t' read -r kind lno val; do
        case "$kind" in
            LABEL)
                case "$HOSTED_LABELS" in *" $val "*) continue ;; esac
                case "$SELF_HOSTED_LABELS" in
                    *" $val "*)
                        if [ "$pr" -eq 1 ]; then
                            err "$lno" R1 "pull_request workflow names runner label '$val'; PR jobs run on GitHub-hosted runners only"
                        elif [ "$selfhosted_ok" -eq 0 ]; then
                            err "$lno" R3 "runner label '$val' is admitted only for files the allowlist names with 'self-hosted'"
                        fi ;;
                    *) err "$lno" R3 "runner label '$val' is not one of:$HOSTED_LABELS" ;;
                esac ;;
            EXPR)
                if grep -Eiq 'vars\.|inputs\.|fromjson' <<< "$val"; then
                    err "$lno" R1 "runs-on from vars./inputs./fromJSON is forbidden (variables are visible to fork PRs): $val"
                else
                    err "$lno" R3 "runs-on must be a literal label, not: $val"
                fi ;;
            GROUP) err "$lno" R3 "runner groups are not GitHub-hosted standard runners: $val" ;;
            ROBAD) err "$lno" R3 "runs-on must be written as a block-style key (one per line): $val" ;;
            QKEY) err "$lno" R2 "YAML complex keys ('? ...') cannot be checked and are not allowed" ;;
            JOBFLOW) err "$lno" R3 "jobs must be written in block style, not as a flow mapping: $val" ;;
            JOBUSES)
                case "$val" in
                    ./*) ;; # local callee: checked as a workflow file of its own
                    *)
                        # A reusable workflow from another repository picks its
                        # runs-on against this repository's runners.
                        if [ "$pr" -eq 1 ]; then
                            err "$lno" R1 "pull_request workflow calls a reusable workflow from another repository: $val"
                        else
                            err "$lno" R3 "reusable workflows from another repository are not allowed (runs-on unchecked): $val"
                        fi ;;
                esac ;;
        esac
    done <<< "$facts"

    grep -q '^PERMS' <<< "$facts" \
        || err "" R4 "no top-level permissions: block (the default token would be broader than needed)"

    [ "$errors" -gt 255 ] && errors=255
    return "$errors"
}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

run_repository() {
    local total=0 files=0 rc f rel copy
    [ -n "$ROOT" ] || ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
    ROOT="$(cd "$ROOT" && pwd)"
    [ -n "$ALLOWLIST" ] || ALLOWLIST="$ROOT/ops/ci/workflow-policy-allowlist.txt"
    load_allowlist "$ALLOWLIST" "$ROOT" || return 1

    for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
        [ -f "$f" ] || continue
        rel="${f#"$ROOT"/}"
        files=$((files + 1))
        rc=0
        check_file "$f" "$rel" || rc=$?
        total=$((total + rc))
    done
    if [ "$files" -eq 0 ]; then
        echo "::error::no workflow files under $ROOT/.github/workflows"
        return 1
    fi

    # R5: nested workflow directories are never run by GitHub; report them.
    while IFS= read -r f; do
        echo "::warning file=${f#"$ROOT"/}::[R5] nested workflow file - GitHub does not run it; not checked"
    done < <(find "$ROOT" -path "$ROOT/.git" -prune -o \
                  -path "$ROOT/.github/workflows" -prune -o \
                  -path '*/.github/workflows/*' \( -name '*.yml' -o -name '*.yaml' \) -print \
             2>/dev/null | sort)

    copy="$ROOT/core/.github/policy/test-workflow-runner-policy.sh"
    if [ -f "$copy" ]; then
        if [ "$(sha256_of "$copy")" = "$(sha256_of "$SCRIPT_PATH")" ]; then
            echo "core copy identical: ${copy#"$ROOT"/}"
        else
            echo "::error file=${copy#"$ROOT"/}::core copy of the runner policy differs from ${SCRIPT_PATH#"$ROOT"/} (sha256)"
            total=$((total + 1))
        fi
    else
        echo "::notice::no core copy at core/.github/policy/ (submodule not checked out or copy absent) - comparison skipped"
    fi

    echo "workflow runner policy: $files file(s), $total error(s)"
    [ "$total" -eq 0 ]
}

run_self_test() {
    local dir="$SCRIPT_DIR/fixtures/workflow-policy" f name out rc expect fail=0 ok=0 bad=0
    [ -d "$dir" ] || { echo "::error::fixture directory $dir missing"; return 1; }
    load_allowlist "$dir/allowlist.txt" "$dir" || return 1
    for f in "$dir"/*.yml; do
        [ -f "$f" ] || continue
        name="$(basename "$f")"
        rc=0
        out="$(check_file "$f" "$name")" || rc=$?
        case "$name" in
            ok*.yml)
                ok=$((ok + 1))
                if [ "$rc" -ne 0 ]; then
                    echo "SELF-TEST FAIL: $name should pass, got $rc error(s):"
                    printf '%s\n' "$out" | sed 's/^/    /'
                    fail=1
                else
                    echo "self-test ok  : $name passes"
                fi ;;
            bad-*.yml)
                bad=$((bad + 1))
                expect="$(sed -n 's/^# expect: *\(R[0-9]\).*/\1/p' "$f" | head -1)"
                if [ -z "$expect" ]; then
                    echo "SELF-TEST FAIL: $name has no '# expect: Rn' header"
                    fail=1
                elif [ "$rc" -eq 0 ]; then
                    echo "SELF-TEST FAIL: $name should fail with $expect but passed"
                    fail=1
                elif ! grep -Fq "[$expect]" <<< "$out"; then
                    echo "SELF-TEST FAIL: $name failed, but not with $expect:"
                    printf '%s\n' "$out" | sed 's/^/    /'
                    fail=1
                else
                    echo "self-test ok  : $name fails with $expect"
                fi ;;
            *) echo "SELF-TEST FAIL: $name is neither ok*.yml nor bad-*.yml"; fail=1 ;;
        esac
    done
    if [ "$ok" -eq 0 ] || [ "$bad" -eq 0 ]; then
        echo "SELF-TEST FAIL: need at least one ok and one bad fixture ($ok ok, $bad bad)"
        fail=1
    fi
    echo "workflow runner policy self-test: $ok ok, $bad bad fixture(s), result $([ "$fail" -eq 0 ] && echo PASS || echo FAIL)"
    [ "$fail" -eq 0 ]
}

if [ "$SELF_TEST" -eq 1 ]; then
    run_self_test
else
    run_repository
fi
