#!/bin/sh
# Runs every check in numeric order and prints one summary.
#
# It does NOT stop at the first failure. Each check is independent and a single
# red one must not hide the state of the rest - the same reason lint.yml keeps
# its jobs separate.
#
# The last rule is the important one: if nothing actually ran - every check
# skipped - this exits non-zero. A green smoke run that proved nothing is worse
# than a red one, because it is believed.
#
# Local use, against a stack you already brought up:
#     sh test/smoke/run-all.sh
#     TWOW_COMPOSE_FILE=deploy/compose/docker-compose.yml sh test/smoke/run-all.sh
#     sh test/smoke/30-bot-persistence.sh        # one check on its own
set -u

dir=$(cd "$(dirname "$0")" && pwd)
passed=0
failed=0
skipped=0
failed_names=""
skipped_names=""

echo "== twow smoke suite =="

# The [0-9][0-9]- prefix is what makes the order explicit and what keeps lib.sh
# out of the run.
for check in "$dir"/[0-9][0-9]-*.sh; do
    [ -f "$check" ] || continue
    sh "$check"
    rc=$?
    name=$(basename "$check" .sh)
    case "$rc" in
        0)  passed=$((passed + 1)) ;;
        77) skipped=$((skipped + 1)); skipped_names="$skipped_names $name" ;;
        *)  failed=$((failed + 1)); failed_names="$failed_names $name" ;;
    esac
done

echo "== summary: $passed passed, $failed failed, $skipped skipped =="
[ -n "$skipped_names" ] && echo "   skipped:$skipped_names"
[ -n "$failed_names" ] && echo "   failed: $failed_names"

if [ "$failed" -gt 0 ]; then
    echo "SMOKE FAILED"
    exit 1
fi

if [ "$passed" -eq 0 ]; then
    echo "SMOKE FAILED: every check skipped - this run proved nothing"
    exit 1
fi

echo "SMOKE OK"
exit 0
