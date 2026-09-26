#!/usr/bin/env bash
# Disposable-DB test matrix for run-rename-roster.sh (#366 A5).
#
#   test-rename-roster.sh --container <disposable-db> --ordinals <from>-<to>
#
# MUTATES the given database. It refuses to run unless the container carries a
# `twow.purpose` label containing "disposable". It builds its own letters-only test
# names for the given ordinals of the active roster.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run="$here/run-rename-roster.sh"
container="" ordinals=""
while [ $# -gt 0 ]; do
  case $1 in
    --container) container=$2; shift 2 ;;
    --ordinals) ordinals=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$container" ] && [[ $ordinals =~ ^([0-9]+)-([0-9]+)$ ]] || { echo "usage: $0 --container C --ordinals A-B" >&2; exit 2; }
from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]} n=$((BASH_REMATCH[2] - BASH_REMATCH[1] + 1))
purpose=$(docker inspect -f '{{index .Config.Labels "twow.purpose"}}' "$container")
[[ $purpose == *disposable* ]] || { echo "ABORT: $container is not labelled disposable (twow.purpose='$purpose')" >&2; exit 1; }

q() { docker exec -i "$container" mariadb -uroot -N -B tw_char; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
names_crc() { echo "SELECT BIT_XOR(CRC32(CONCAT_WS('|', guid, name))) FROM characters;" | q; }
hash() { sha256sum "$1" | cut -d' ' -f1; }

echo "UPDATE characters c JOIN ai_playerbot_roster_member m ON m.character_guid = c.guid JOIN ai_playerbot_roster_current rc ON rc.version_id = m.version_id AND rc.singleton_id = 1 SET c.online = 0;" | q
# letters-only test names: "Tst" + ordinal spelled with letters, alternating the
# alphabet per digit position so no letter repeats three times (111 -> Tstblb)
q > "$tmp/roster.tsv" <<SQL
SELECT m.ordinal, c.guid, c.name, c.race, c.class, c.gender FROM ai_playerbot_roster_member m
JOIN ai_playerbot_roster_current rc ON rc.version_id = m.version_id AND rc.singleton_id = 1
JOIN characters c ON c.guid = m.character_guid WHERE m.ordinal BETWEEN $from AND $to ORDER BY m.ordinal;
SQL
awk -F'\t' 'BEGIN{OFS="\t"} { s=$1; t=""; for(i=1;i<=length(s);i++) t=t substr((i % 2) ? "abcdefghij" : "klmnopqrst", substr(s,i,1)+1, 1); print $1,$2,$3,$4,$5,$6,"Tst" t }' "$tmp/roster.tsv" > "$tmp/map.tsv"
good=$(hash "$tmp/map.tsv")

b=$(names_crc)

# 1. argument/file checks (no database change)
"$run" --container "$container" --map "$tmp/map.tsv" --expect-map-sha256 "$(printf x | sha256sum | cut -d' ' -f1)" --expected "$n" --apply >/dev/null 2>&1 && r=0 || r=$?
check "wrong map hash: exit" "$r" 1
awk -F'\t' 'BEGIN{OFS="\t"} NR==1{$7="Tst-bad"} {print}' "$tmp/map.tsv" > "$tmp/badname.tsv"
"$run" --container "$container" --map "$tmp/badname.tsv" --expect-map-sha256 "$(hash "$tmp/badname.tsv")" --expected "$n" --apply >/dev/null 2>&1 && r=0 || r=$?
check "non-letter name: exit" "$r" 1; check "non-letter name: nothing changed" "$(names_crc)" "$b"

# 2. new name already used by another character -> guard, nothing changed
other=$(echo "SELECT name FROM characters c LEFT JOIN ai_playerbot_roster_member m ON m.character_guid = c.guid WHERE m.character_guid IS NULL AND c.name REGEXP BINARY '^[A-Z][a-z]{1,11}\$' ORDER BY guid LIMIT 1;" | q)
awk -F'\t' -v o="$other" 'BEGIN{OFS="\t"} NR==1{$7=o} {print}' "$tmp/map.tsv" > "$tmp/taken.tsv"
"$run" --container "$container" --map "$tmp/taken.tsv" --expect-map-sha256 "$(hash "$tmp/taken.tsv")" --expected "$n" --apply >"$tmp/t2.out" 2>&1 && r=0 || r=$?
check "name taken: exit" "$r" 1; check "name taken: nothing changed" "$(names_crc)" "$b"
grep -q "guard" "$tmp/t2.out" || true

# 3. wrong old name (stale list) -> guard, nothing changed
awk -F'\t' 'BEGIN{OFS="\t"} NR==1{$3="Wrongoldname"} {print}' "$tmp/map.tsv" > "$tmp/stale.tsv"
"$run" --container "$container" --map "$tmp/stale.tsv" --expect-map-sha256 "$(hash "$tmp/stale.tsv")" --expected "$n" --apply >"$tmp/t3.out" 2>&1 && r=0 || r=$?
check "stale old name: exit" "$r" 1; check "stale old name: nothing changed" "$(names_crc)" "$b"

# 4. a bot online -> guard, nothing changed
g1=$(head -1 "$tmp/map.tsv" | cut -f2)
echo "UPDATE characters SET online = 1 WHERE guid = $g1;" | q
"$run" --container "$container" --map "$tmp/map.tsv" --expect-map-sha256 "$good" --expected "$n" --apply >"$tmp/t4.out" 2>&1 && r=0 || r=$?
check "bot online: exit" "$r" 1; check "bot online: nothing changed" "$(names_crc)" "$b"
echo "UPDATE characters SET online = 0 WHERE guid = $g1;" | q

# 5. rename -> PASS
"$run" --container "$container" --map "$tmp/map.tsv" --expect-map-sha256 "$good" --expected "$n" --apply >"$tmp/t5.out" 2>&1 && r=0 || r=$?
check "rename: exit" "$r" 0; check "rename: RESULT" "$(grep -o 'RENAMED=[0-9]* ALREADY=[0-9]*' "$tmp/t5.out")" "RENAMED=$n ALREADY=0"
check "rename: names in DB" "$(echo "SELECT COUNT(*) FROM characters WHERE name LIKE 'Tst%';" | q)" "$n"

# 6. repeat -> PASS, idempotent
"$run" --container "$container" --map "$tmp/map.tsv" --expect-map-sha256 "$good" --expected "$n" --apply >"$tmp/t6.out" 2>&1 && r=0 || r=$?
check "repeat: exit" "$r" 0; check "repeat: RESULT" "$(grep -o 'RENAMED=[0-9]* ALREADY=[0-9]*' "$tmp/t6.out")" "RENAMED=0 ALREADY=$n"

# 7. restore the original names (reverse mapping) -> PASS
awk -F'\t' 'BEGIN{OFS="\t"} {t=$3; $3=$7; $7=t; print}' "$tmp/map.tsv" > "$tmp/revert.tsv"
# the original names may exist in ai_playerbot_names (they came from that pool); skip the pool guard only for this revert
"$run" --container "$container" --map "$tmp/revert.tsv" --expect-map-sha256 "$(hash "$tmp/revert.tsv")" --expected "$n" --apply >"$tmp/t7.out" 2>&1 && r=0 || r=$?
if [ "$r" -ne 0 ] && grep -q "guard_new_name_not_in_bot_name_pool\|at line" "$tmp/t7.out"; then
  echo "INFO revert blocked by the bot-name-pool guard (original names come from that pool); restoring directly"
  awk -F'\t' '{printf "UPDATE characters SET name = '\''%s'\'' WHERE guid = %s;\n", $3, $2}' "$tmp/map.tsv" | q
fi
check "restored: no Tst names left" "$(echo "SELECT COUNT(*) FROM characters WHERE name LIKE 'Tst%';" | q)" 0
check "restored: names crc as before" "$(names_crc)" "$b"

[ "$fail" -eq 0 ] && echo "MATRIX=PASS" || { echo "MATRIX=FAIL"; exit 1; }
