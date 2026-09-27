#!/usr/bin/env bash
# Disposable-DB test matrix for run-talent-reset.sh (#366, #357).
#
#   test-talent-reset.sh --container <disposable-db> [--class 7 --spec-nos 2,4]
#
# MUTATES the given database. Refuses containers without a `twow.purpose` label containing
# "disposable".
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run="$here/run-talent-reset.sh"
container="" cls=7 specs=2,4
while [ $# -gt 0 ]; do
  case $1 in
    --container) container=$2; shift 2 ;;
    --class) cls=$2; shift 2 ;;
    --spec-nos) specs=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$container" ] || { echo "usage: $0 --container C [--class N --spec-nos A,B]" >&2; exit 2; }
purpose=$(docker inspect -f '{{index .Config.Labels "twow.purpose"}}' "$container")
[[ $purpose == *disposable* ]] || { echo "ABORT: $container is not labelled disposable (twow.purpose='$purpose')" >&2; exit 1; }

q() { docker exec -i "$container" mariadb -uroot -N -B tw_char; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
state() { echo "CHECKSUM TABLE characters, cv_bots.ai_playerbot_random_bots EXTENDED;" | q | sha256sum | cut -c1-16; }
roster="JOIN ai_playerbot_roster_member m ON m.character_guid = c.guid JOIN ai_playerbot_roster_current rc ON rc.version_id = m.version_id AND rc.singleton_id = 1"
flagged() { echo "SELECT COUNT(*) FROM characters c $roster WHERE c.at_login & 4 = 4;" | q; }

# Setup: the whole roster offline and without the talent-reset bit.
echo "UPDATE characters c $roster SET c.online = 0, c.at_login = c.at_login & ~4;" | q

# 1. dry run: read-only, prints count and hash
b=$(state)
"$run" --container "$container" --class "$cls" --spec-nos "$specs" --dry-run >"$tmp/t1.out" 2>&1 && r=0 || r=$?
check "dry run: exit" "$r" 0; check "dry run: nothing changed" "$(state)" "$b"
n=$(sed -n 's/^TARGETS=\([0-9]*\) .*/\1/p' "$tmp/t1.out"); h=$(sed -n 's/.* GUID_SHA256=\([0-9a-f]*\) .*/\1/p' "$tmp/t1.out")
want=$(echo "SELECT COUNT(*) FROM characters c $roster JOIN cv_bots.ai_playerbot_random_bots e ON e.owner = 0 AND e.bot = c.guid AND e.event = 'specNo' WHERE c.class = $cls AND FIND_IN_SET(e.value, '$specs');" | q)
check "dry run: target count matches an independent query" "$n" "$want"
[ "${n:-0}" -gt 0 ] || { echo "FAIL no targets in this database"; exit 1; }

# 2. argument checks
"$run" --container "$container" --class "$cls" --spec-nos "$specs" --apply >/dev/null 2>&1 && r=0 || r=$?; check "apply without hash: exit" "$r" 2
# 3. wrong hash -> guard abort, nothing changed
"$run" --container "$container" --class "$cls" --spec-nos "$specs" --expected "$n" --expect-guid-sha256 "$(printf x | sha256sum | cut -d' ' -f1)" --apply >"$tmp/t3.out" 2>&1 && r=0 || r=$?
check "wrong hash: exit" "$r" 1; check "wrong hash: nothing changed" "$(state)" "$b"
# 4. a target online -> guard abort, nothing changed
g=$(echo "SELECT c.guid FROM characters c $roster JOIN cv_bots.ai_playerbot_random_bots e ON e.owner = 0 AND e.bot = c.guid AND e.event = 'specNo' WHERE c.class = $cls AND FIND_IN_SET(e.value, '$specs') ORDER BY c.guid LIMIT 1;" | q)
echo "UPDATE characters SET online = 1 WHERE guid = $g;" | q; b4=$(state)
"$run" --container "$container" --class "$cls" --spec-nos "$specs" --expected "$n" --expect-guid-sha256 "$h" --apply >"$tmp/t4.out" 2>&1 && r=0 || r=$?
check "target online: exit" "$r" 1; check "target online: nothing changed" "$(state)" "$b4"
echo "UPDATE characters SET online = 0 WHERE guid = $g;" | q
# 5. apply -> PASS, exactly the targets flagged
"$run" --container "$container" --class "$cls" --spec-nos "$specs" --expected "$n" --expect-guid-sha256 "$h" --apply >"$tmp/t5.out" 2>&1 && r=0 || r=$?
check "apply: exit" "$r" 0; check "apply: RESULT" "$(grep -o 'RESULT=PASS guards=4 asserts_pass=4' "$tmp/t5.out" || true)" "RESULT=PASS guards=4 asserts_pass=4"
check "apply: exactly the targets carry the bit" "$(flagged)" "$n"
# 6. repeat -> PASS, idempotent
"$run" --container "$container" --class "$cls" --spec-nos "$specs" --expected "$n" --expect-guid-sha256 "$h" --apply >"$tmp/t6.out" 2>&1 && r=0 || r=$?
check "repeat: exit" "$r" 0; check "repeat: still exactly the targets" "$(flagged)" "$n"

[ "$fail" -eq 0 ] && echo "MATRIX=PASS" || { echo "MATRIX=FAIL"; exit 1; }
