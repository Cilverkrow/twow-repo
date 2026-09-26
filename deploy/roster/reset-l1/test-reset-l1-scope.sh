#!/usr/bin/env bash
# Disposable-DB test matrix for the reset-l1 target scope (#366 A1).
#
#   test-reset-l1-scope.sh --container <disposable-db> --csv <roster.csv> --ordinals <from>-<to>
#
# MUTATES the given database. It refuses to run unless the container carries a
# `twow.purpose` label containing "disposable". Never point it at a live stack.
#
# Cases: argument validation; wrong GUID hash -> guard abort, no change; a player
# character inside the scope -> guard abort, no change; scoped reset -> PASS and the
# members outside the scope are byte-identical (full-row fingerprint); repeat -> PASS;
# full-scope run without --ordinals -> PASS (the #334 behaviour).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run="$here/run-reset-l1.sh"
container="" csv="" ordinals=""
while [ $# -gt 0 ]; do
  case $1 in
    --container) container=$2; shift 2 ;;
    --csv) csv=$2; shift 2 ;;
    --ordinals) ordinals=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$container" ] && [ -f "$csv" ] && [[ $ordinals =~ ^([0-9]+)-([0-9]+)$ ]] ||
  { echo "usage: $0 --container C --csv F --ordinals A-B" >&2; exit 2; }
from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]} n=$((BASH_REMATCH[2] - BASH_REMATCH[1] + 1))
purpose=$(docker inspect -f '{{index .Config.Labels "twow.purpose"}}' "$container")
[[ $purpose == *disposable* ]] || { echo "ABORT: $container is not labelled disposable (twow.purpose='$purpose')" >&2; exit 1; }

q() { docker exec -i "$container" mariadb -uroot -N -B tw_char; }
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
total=$(echo "SELECT COUNT(*) FROM ai_playerbot_roster_member m JOIN ai_playerbot_roster_current c ON c.version_id = m.version_id WHERE c.singleton_id = 1;" | q)
fingerprint() {  # full-row fingerprint of roster members outside the scope, plus all non-roster characters
  q <<SQL
SET SESSION group_concat_max_len = 16777216;
CREATE TEMPORARY TABLE s (guid INT UNSIGNED PRIMARY KEY) SELECT m.character_guid AS guid FROM ai_playerbot_roster_member m
  JOIN ai_playerbot_roster_current c ON c.version_id = m.version_id WHERE c.singleton_id = 1 AND m.ordinal BETWEEN $from AND $to;
SELECT SHA2(CONCAT_WS('#',
  (SELECT GROUP_CONCAT(CONCAT_WS('|', guid, name, level, xp, money, map, position_x, position_y, at_login) ORDER BY guid) FROM characters WHERE guid NOT IN (SELECT guid FROM s)),
  (SELECT GROUP_CONCAT(CONCAT_WS('|', guid, bag, slot, item) ORDER BY guid, bag, slot) FROM character_inventory WHERE guid NOT IN (SELECT guid FROM s)),
  (SELECT GROUP_CONCAT(CONCAT_WS('|', guid, skill, value, max) ORDER BY guid, skill) FROM character_skills WHERE guid NOT IN (SELECT guid FROM s)),
  (SELECT GROUP_CONCAT(CONCAT_WS('|', guid, quest, status, rewarded) ORDER BY guid, quest) FROM character_queststatus WHERE guid NOT IN (SELECT guid FROM s)),
  (SELECT GROUP_CONCAT(CONCAT_WS('|', guid, map, zone, position_x) ORDER BY guid) FROM character_homebind WHERE guid NOT IN (SELECT guid FROM s))), 256);
SQL
}
all_fingerprint() { echo "CHECKSUM TABLE characters, character_inventory, character_skills, character_queststatus, character_homebind, item_instance EXTENDED;" | q | sha256sum | cut -c1-16; }

# Setup: every roster member offline and above level 1, so a reset is visible.
echo "UPDATE characters c JOIN ai_playerbot_roster_member m ON m.character_guid = c.guid JOIN ai_playerbot_roster_current rc ON rc.version_id = m.version_id AND rc.singleton_id = 1 SET c.online = 0, c.level = 10 + m.ordinal % 20;" | q
good=$("$run" --hash-from-csv "$csv" --ordinals "$ordinals")

# 1. argument validation (no database access)
"$run" --container "$container" --expected "$n" --ordinals "$ordinals" --apply >/dev/null 2>&1 && r=0 || r=$?; check "args: --ordinals without hash" "$r" 2
"$run" --container "$container" --expected "$((n + 1))" --ordinals "$ordinals" --expect-guid-sha256 "$good" --apply >/dev/null 2>&1 && r=0 || r=$?; check "args: --expected != range" "$r" 2

# 2. wrong hash -> abort before any mutation
b=$(all_fingerprint)
"$run" --container "$container" --expected "$n" --ordinals "$ordinals" --expect-guid-sha256 "$(printf x | sha256sum | cut -d' ' -f1)" --apply >/tmp/t2.out 2>&1 && r=0 || r=$?
check "wrong hash: exit" "$r" 1; check "wrong hash: nothing changed" "$(all_fingerprint)" "$b"

# 3. player character inside the scope (hash matches the swapped set) -> abort
player=$(echo "SELECT c.guid FROM characters c JOIN tw_logon.account a ON a.id = c.account WHERE a.username NOT LIKE 'RNDBOT%' ORDER BY c.guid LIMIT 1;" | q)
victim_ord=$from; victim=$(echo "SELECT m.character_guid FROM ai_playerbot_roster_member m JOIN ai_playerbot_roster_current c ON c.version_id = m.version_id AND c.singleton_id = 1 WHERE m.ordinal = $victim_ord;" | q)
echo "UPDATE ai_playerbot_roster_member m JOIN ai_playerbot_roster_current c ON c.version_id = m.version_id AND c.singleton_id = 1 SET m.character_guid = $player WHERE m.ordinal = $victim_ord;" | q
swapped=$(awk -F, -v a="$from" -v b="$to" -v o="$victim_ord" -v p="$player" 'NR > 1 && $1 >= a && $1 <= b { printf "%s%s:%s", (n++ ? "," : ""), $1, ($1 == o ? p : $2) }' "$csv" | sha256sum | cut -d' ' -f1)
b=$(all_fingerprint)
"$run" --container "$container" --expected "$n" --ordinals "$ordinals" --expect-guid-sha256 "$swapped" --apply >/tmp/t3.out 2>&1 && r=0 || r=$?
check "player in scope: exit" "$r" 1; check "player in scope: nothing changed" "$(all_fingerprint)" "$b"
echo "UPDATE ai_playerbot_roster_member m JOIN ai_playerbot_roster_current c ON c.version_id = m.version_id AND c.singleton_id = 1 SET m.character_guid = $victim WHERE m.ordinal = $victim_ord;" | q

# 4. scoped reset -> PASS, outside the scope unchanged
before=$(fingerprint)
"$run" --container "$container" --expected "$n" --ordinals "$ordinals" --expect-guid-sha256 "$good" --apply >/tmp/t4.out 2>&1 && r=0 || r=$?
check "scoped reset: exit" "$r" 0; check "scoped reset: RESULT" "$(grep -o 'RESULT=PASS guards=8' /tmp/t4.out || true)" "RESULT=PASS guards=8"
check "scoped reset: outside scope byte-identical" "$(fingerprint)" "$before"
in_l1=$(echo "SELECT SUM(c.level = 1) FROM characters c JOIN ai_playerbot_roster_member m ON m.character_guid = c.guid JOIN ai_playerbot_roster_current rc ON rc.version_id = m.version_id AND rc.singleton_id = 1 WHERE m.ordinal BETWEEN $from AND $to;" | q)
out_l1=$(echo "SELECT COALESCE(SUM(c.level = 1), 0) FROM characters c JOIN ai_playerbot_roster_member m ON m.character_guid = c.guid JOIN ai_playerbot_roster_current rc ON rc.version_id = m.version_id AND rc.singleton_id = 1 WHERE m.ordinal NOT BETWEEN $from AND $to;" | q)
check "scoped reset: all in scope level 1" "$in_l1" "$n"; check "scoped reset: nobody outside scope level 1" "$out_l1" 0

# 5. repeat -> PASS
"$run" --container "$container" --expected "$n" --ordinals "$ordinals" --expect-guid-sha256 "$good" --apply >/tmp/t5.out 2>&1 && r=0 || r=$?
check "repeat: exit" "$r" 0

# 6. full scope (the #334 behaviour) -> PASS
"$run" --container "$container" --expected "$total" --apply >/tmp/t6.out 2>&1 && r=0 || r=$?
check "full scope: exit" "$r" 0

[ "$fail" -eq 0 ] && echo "MATRIX=PASS" || { echo "MATRIX=FAIL"; exit 1; }
