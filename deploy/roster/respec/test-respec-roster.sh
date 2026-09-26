#!/usr/bin/env bash
# Disposable-DB test matrix for run-respec-roster.sh (#366 A6).
#
#   test-respec-roster.sh --container <disposable-db> --csv <roster-plan.csv> --ordinals <from>-<to>
#
# MUTATES the given database. Refuses containers without a `twow.purpose` label containing
# "disposable". The plan's rows in the range must be the active roster at those ordinals.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run="$here/run-respec-roster.sh"
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
from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]}
purpose=$(docker inspect -f '{{index .Config.Labels "twow.purpose"}}' "$container")
[[ $purpose == *disposable* ]] || { echo "ABORT: $container is not labelled disposable (twow.purpose='$purpose')" >&2; exit 1; }

q() { docker exec -i "$container" mariadb -uroot -N -B tw_char; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
state() { echo "CHECKSUM TABLE characters, character_skills, character_spell, cv_bots.ai_playerbot_random_bots EXTENDED;" | q | sha256sum | cut -c1-16; }
good=$(awk -F, -v a="$from" -v b="$to" 'NR > 1 && $1 >= a && $1 <= b { printf "%s%s:%s", (n++ ? "," : ""), $1, $2 }' "$csv" | sha256sum | cut -d' ' -f1)
# test-only spec index: the real one plus "bear" as 11.3 (twow-core#308 adds it for real)
{ cat "$here/premade-spec-index.tsv"; printf '11\t3\tbear\n'; } > "$tmp/index-with-bear.tsv"

echo "UPDATE characters c JOIN ai_playerbot_roster_member m ON m.character_guid = c.guid JOIN ai_playerbot_roster_current rc ON rc.version_id = m.version_id AND rc.singleton_id = 1 SET c.online = 0, c.at_login = c.at_login & ~4;" | q
# Synthetic profession state on two pair-changed bots: one gets a skill of a pair it is
# leaving (must be removed with its spell), one gets a skill of its new pair (must stay).
leaver=$(awk -F, -v a="$from" -v b="$to" 'NR > 1 && $1 >= a && $1 <= b && $10 == "Herbalism/Alchemy" { print $2; exit }' "$csv")
keeper=$(awk -F, -v a="$from" -v b="$to" -v l="$leaver" 'NR > 1 && $1 >= a && $1 <= b && $10 == "Herbalism/Alchemy" && $2 != l { print $2; exit }' "$csv")
q <<SQL
DELETE FROM character_skills WHERE guid IN ($leaver, $keeper) AND skill IN (393, 182);
DELETE FROM character_spell WHERE guid IN ($leaver, $keeper) AND spell IN (8613, 2366);
INSERT INTO character_skills (guid, skill, value, max) VALUES ($leaver, 393, 12, 75), ($keeper, 182, 15, 75);
INSERT INTO character_spell (guid, spell, active, disabled) VALUES ($leaver, 8613, 1, 0), ($keeper, 2366, 1, 0);
UPDATE cv_bots.ai_playerbot_random_bots SET value = 2 WHERE owner = 0 AND event = 'profession_pair' AND bot IN ($leaver, $keeper);
SQL

# 1. talent path not in the spec index (the real index has no bear yet) -> abort before DB
b=$(state)
"$run" --container "$container" --csv "$csv" --ordinals "$ordinals" --expect-guid-sha256 "$good" --apply >"$tmp/t1.out" 2>&1 && r=0 || r=$?
check "bear missing from index: exit" "$r" 1; check "bear missing: reason" "$(grep -c 'not in the spec index' "$tmp/t1.out")" 1
# 2. wrong GUID hash -> abort before DB
"$run" --container "$container" --csv "$csv" --ordinals "$ordinals" --expect-guid-sha256 "$(printf x | sha256sum | cut -d' ' -f1)" --spec-index "$tmp/index-with-bear.tsv" --apply >"$tmp/t2.out" 2>&1 && r=0 || r=$?
check "wrong hash: exit" "$r" 1
# 3. unknown profession label -> abort before DB
awk -F, -v OFS=, -v a="$from" 'NR > 1 && $1 == a { $10 = "Fishing/Cooking" } { print }' "$csv" > "$tmp/badpair.csv"
"$run" --container "$container" --csv "$tmp/badpair.csv" --ordinals "$ordinals" --expect-guid-sha256 "$good" --spec-index "$tmp/index-with-bear.tsv" --apply >"$tmp/t3.out" 2>&1 && r=0 || r=$?
check "unknown pair: exit" "$r" 1; check "no DB change after 1-3" "$(state)" "$b"
# 4. a bot online -> guard abort, nothing changed
g1=$(awk -F, -v a="$from" 'NR > 1 && $1 == a { print $2 }' "$csv")
echo "UPDATE characters SET online = 1 WHERE guid = $g1;" | q; b=$(state)
"$run" --container "$container" --csv "$csv" --ordinals "$ordinals" --expect-guid-sha256 "$good" --spec-index "$tmp/index-with-bear.tsv" --apply >"$tmp/t4.out" 2>&1 && r=0 || r=$?
check "bot online: exit" "$r" 1; check "bot online: nothing changed" "$(state)" "$b"
echo "UPDATE characters SET online = 0 WHERE guid = $g1;" | q
# 5. apply -> PASS
"$run" --container "$container" --csv "$csv" --ordinals "$ordinals" --expect-guid-sha256 "$good" --spec-index "$tmp/index-with-bear.tsv" --apply >"$tmp/t5.out" 2>&1 && r=0 || r=$?
check "apply: exit" "$r" 0; grep -E 'RESPEC=|RESULT=' "$tmp/t5.out"
check "leaver lost foreign skill 393" "$(echo "SELECT COUNT(*) FROM character_skills WHERE guid = $leaver AND skill = 393;" | q)" 0
check "leaver lost skinning spell 8613" "$(echo "SELECT COUNT(*) FROM character_spell WHERE guid = $leaver AND spell = 8613;" | q)" 0
check "keeper kept herbalism 182" "$(echo "SELECT COUNT(*) FROM character_skills WHERE guid = $keeper AND skill = 182;" | q)" 1
check "keeper kept herb spell 2366" "$(echo "SELECT COUNT(*) FROM character_spell WHERE guid = $keeper AND spell = 2366;" | q)" 1
# 6. repeat -> PASS, nothing to do
"$run" --container "$container" --csv "$csv" --ordinals "$ordinals" --expect-guid-sha256 "$good" --spec-index "$tmp/index-with-bear.tsv" --apply >"$tmp/t6.out" 2>&1 && r=0 || r=$?
check "repeat: exit" "$r" 0; check "repeat: nothing left to do" "$(grep -o 'RESPEC=0 PAIR_CHANGE=0' "$tmp/t6.out")" "RESPEC=0 PAIR_CHANGE=0"

[ "$fail" -eq 0 ] && echo "MATRIX=PASS" || { echo "MATRIX=FAIL"; exit 1; }
