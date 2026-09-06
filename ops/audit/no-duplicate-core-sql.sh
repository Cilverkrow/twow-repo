#!/usr/bin/env bash
# Fail if the platform grows a second copy of the core's SQL tree.
#
# WHAT THIS PREVENTS. The repository used to carry sql/ at the root: a
# near-duplicate of core/sql from its own submodule. Nothing kept the two in
# step, so core moved on and the copy did not. deploy/compose/db-init.sh read
# the copy, so a server image built from a newer core was bootstrapped against
# an older schema and died at world load with
#     Table 'tw_world.skill_race_class_info_mod' doesn't exist
# and exit 134 -- a crash with no mention anywhere of the duplicate tree that
# caused it. By the time it was measured the copy was missing 16 of core's
# files and its create_databases.sql was behind by the one table above.
#
# Two checks, because a duplicate can come back under either shape:
#
#   1. Structural. A `sql/` directory at the repository root is the exact thing
#      that was removed; it must not return, whatever is in it.
#   2. Content. Any platform-side SQL file that is a CRLF-normalised byte-copy
#      of a file under core/sql/ is the same mistake wearing a different name.
#      Normalisation is not optional: the two trees differed only in line
#      endings for six files, so a raw comparison calls those distinct and
#      finds nothing.
#
# Exempt, and each for its own reason: modules/*, because a module owns its own
# tables (ADR-0021) and its schema is genuinely not core's; runbooks/, because
# those are frozen evidence captures that must keep saying what they said on the
# day, duplicate or not.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

fail=0
err() { printf '::error::%s\n' "$*" >&2; fail=1; }

# ---------------------------------------------------------------- structural
if [ -e sql ]; then
    err "sql/ is back at the repository root."
    err "That tree was a stale duplicate of core/sql and broke the bootstrap."
    err "Core SQL belongs in the twow-core submodule; send changes there."
fi

# ------------------------------------------------------------------- content
# Candidates first: every tracked SQL file outside core/ and outside a module's
# own tree. Building the core index costs a pass over core/sql/base (~130 MB),
# so it is only worth paying for when there is something to compare it against.
candidates=$(git ls-files -- '*.sql' | grep -Ev '^(core|modules|runbooks)/' || true)

if [ -n "$candidates" ]; then
    # Reported rather than skipped: a job that forgot `submodules: recursive`
    # must not turn an uncheckable guard into a silent green.
    if [ ! -d core/sql ]; then
        err "core/sql is not checked out, so the duplicate-content check cannot run"
        err "add 'submodules: recursive' to this job's checkout"
        exit "$fail"
    fi

    # Normalise CRLF away before hashing; that is the whole difficulty here.
    norm_hash() { sed 's/\r$//' "$1" | git hash-object --stdin; }

    hashes=$(mktemp)
    trap 'rm -f "$hashes"' EXIT
    while IFS= read -r f; do
        printf '%s\t%s\n' "$(norm_hash "$f")" "$f"
    done < <(find core/sql -type f -name '*.sql' | sort) > "$hashes"

    while IFS= read -r f; do
        h=$(norm_hash "$f")
        match=$(awk -v h="$h" -F'\t' '$1 == h { print $2; exit }' "$hashes")
        if [ -n "$match" ]; then
            err "$f is a duplicate of $match (identical after CRLF normalisation)"
            err "delete it and read the core's copy instead"
        fi
    done <<< "$candidates"
fi

exit "$fail"
