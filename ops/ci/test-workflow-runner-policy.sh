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
# mention a label or a trigger are never findings.
#
#   R1  A workflow triggered by `pull_request` may not name `self-hosted`, or any
#       label that only the self-hosted allowlist admits, in `runs-on:` or in its
#       `labels:` entries. `runs-on` built from `vars.`, `inputs.` or `fromJSON`
#       is forbidden in every workflow: repository variables are visible to fork
#       PRs, so one variable would move every fork PR onto a self-hosted runner.
#   R2  `pull_request_target` and `issue_comment` are forbidden. `workflow_run`
#       is allowed only in files the allowlist names with `workflow_run`, and
#       those files must check `head_branch`, `event == 'push'` and
#       `head_repository.full_name`.
#   R3  `runs-on` admits only the literal labels ubuntu-latest, ubuntu-24.04,
#       windows-latest and windows-2022. Expressions and runner groups are not
#       literals. `self-hosted` (with the default self-hosted labels linux, x64,
#       arm64, windows, macos) is admitted only in files the allowlist names
#       with `self-hosted`.
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
#   EXPR    <line> <expression>
#   GROUP   <line> <group>
#   PERMS   <line>
#   CODE    <text>      (every non-comment line outside block scalars)
#   BODY    <text>      (every non-comment line inside a block scalar)
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
    function value_of(s) { sub(/^[^:]*:/, "", s); return trim(nocomment(s)) }
    function emit_label(v, lno) {
        v = unquote(v)
        if (v == "") return
        if (v ~ /\$\{\{/) { print "EXPR\t" lno "\t" v; return }
        if (v ~ /^\{/)    { print "EXPR\t" lno "\t" v; return }
        print "LABEL\t" lno "\t" tolower(v)
    }
    function emit_flow(v, lno,   n, i, parts) {
        if (v ~ /\$\{\{/) { print "EXPR\t" lno "\t" v; return }
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
    {
        line = $0
        sub(/\r$/, "", line)
        if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) next
        i = ind(line)

        # Body of a block scalar: everything indented deeper than its key line.
        if (inblock) { if (i > blockind) { print "BODY\t" line; next }; inblock = 0 }

        print "CODE\t" line

        # Leaving the on: or runs-on: block.
        if (inon && i == 0) inon = 0
        if (inro && i <= roind) inro = 0

        body = trim(line)
        item = body
        sub(/^-[ \t]*/, "", item)

        if (i == 0 && (body ~ /^("on"|on|true):/ || index(body, q "on" q ":") == 1)) {
            v = value_of(body)
            if (v ~ /^\{/) print "TRIGGER\t{flow-mapping}"
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

        if (i == 0 && body ~ /^permissions:/) print "PERMS\t" NR

        if (item ~ /^runs-on:/) {
            v = value_of(item)
            if (v == "") { inro = 1; roind = i }
            else if (v ~ /^\[/) emit_flow(v, NR)
            else emit_label(v, NR)
        } else if (inro) {
            if (body ~ /^-/) emit_label(nocomment(item), NR)
            else if (item ~ /^labels:/) {
                v = value_of(item)
                if (v ~ /^\[/) emit_flow(v, NR); else if (v != "") emit_label(v, NR)
            } else if (item ~ /^group:/) print "GROUP\t" NR "\t" value_of(item)
            else print "EXPR\t" NR "\t" body
        }

        if (nocomment(line) ~ /:[ \t]*[|>][-+0-9]*[ \t]*$/) { inblock = 1; blockind = i }
    }
    ' "$1"
}

# check_file <absolute file> <path relative to the allowlist base>
# Prints annotations; returns the number of errors (capped at 255).
check_file() {
    local file="$1" rel="$2" facts code errors=0 pr=0 trig kind lno val
    local selfhosted_ok=0
    facts="$(extract_facts "$file")"
    # Guards may sit in a folded `if: >-` scalar, so block bodies count here;
    # comment lines never do.
    code="$(grep -E '^(CODE|BODY)' <<< "$facts" || true)"
    listed "$ALLOW_SELF_HOSTED" "$rel" && selfhosted_ok=1

    err() { echo "::error file=$rel${1:+,line=$1}::[$2] $3"; errors=$((errors + 1)); }

    while IFS=$'\t' read -r kind trig; do
        [ "$kind" = TRIGGER ] || continue
        case "$trig" in
            pull_request) pr=1 ;;
            '{flow-mapping}')
                pr=1
                err "" R2 "'on:' written as a flow mapping cannot be checked; use the block form" ;;
            pull_request_target|issue_comment)
                err "" R2 "trigger '$trig' runs with base-repository privileges on foreign input and is forbidden" ;;
            workflow_run)
                if ! listed "$ALLOW_WORKFLOW_RUN" "$rel"; then
                    err "" R2 "workflow_run is allowed only in files the allowlist names with 'workflow_run'"
                else
                    grep -q 'head_branch' <<< "$code" \
                        || err "" R2 "workflow_run without a head_branch guard"
                    grep -Eq "event[[:space:]]*==[[:space:]]*'push'" <<< "$code" \
                        || err "" R2 "workflow_run without an event == 'push' guard"
                    grep -q 'head_repository\.full_name' <<< "$code" \
                        || err "" R2 "workflow_run without a head_repository.full_name guard"
                fi ;;
        esac
    done <<< "$facts"

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
