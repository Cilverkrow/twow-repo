#!/usr/bin/env bash
# Wrapper for rename-roster.sql (twow-repo#366 A5).
#
#   run-rename-roster.sh --container <db> --map <mapping.tsv> --expect-map-sha256 <hex>
#                        --expected <n> [--conf <mangosd.conf>] --apply
#
# Mapping file: tab-separated, no header, one row per bot:
#   ordinal  guid  old_name  race  class  gender  new_name
# (the format of the approved name draft). Its SHA-256 must equal --expect-map-sha256,
# which is the value the owner approved. Names are validated here (letters only) before
# they are put into SQL, and again by the guards.
#
# Without --conf the client connects as root over the container's socket (disposable
# test databases). With --conf the CharacterDatabase credentials come from that file and
# are passed only through MYSQL_PWD; they are never printed.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sql="$here/rename-roster.sql"
container="" map="" expect_hash="" expected="" conf="" apply=""
while [ $# -gt 0 ]; do
  case $1 in
    --container) container=$2; shift 2 ;;
    --map) map=$2; shift 2 ;;
    --expect-map-sha256) expect_hash=$2; shift 2 ;;
    --expected) expected=$2; shift 2 ;;
    --conf) conf=$2; shift 2 ;;
    --apply) apply=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$container" ] && [ -f "$map" ] && [[ $expect_hash =~ ^[0-9a-f]{64}$ ]] && [[ $expected =~ ^[1-9][0-9]*$ ]] ||
  { echo "usage: $0 --container C --map F --expect-map-sha256 H --expected N [--conf F] --apply" >&2; exit 2; }
[ -n "$apply" ] || { echo "refusing to run without --apply (this renames characters)" >&2; exit 2; }
actual=$(sha256sum "$map" | cut -d' ' -f1)
[ "$actual" = "$expect_hash" ] || { echo "mapping SHA-256 $actual does not match the approved $expect_hash" >&2; exit 1; }

# Build the VALUES list; reject anything that is not a plain letters-only name.
values=$(awk -F'\t' -v n="$expected" '
  NF != 7 { bad = "wrong column count at line " NR; exit }
  $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { bad = "non-numeric ordinal/guid at line " NR; exit }
  $3 !~ /^[A-Za-z]+$/ || $7 !~ /^[A-Za-z]+$/ { bad = "non-letter name at line " NR; exit }
  { printf "%s(%s,%s,'\''%s'\'','\''%s'\'')", (NR > 1 ? "," : ""), $1, $2, $3, $7 }
  END { if (bad) { print bad > "/dev/stderr"; exit 1 } if (NR != n) { print "row count " NR " != --expected " n > "/dev/stderr"; exit 1 } }' "$map")

user=root
if [ -n "$conf" ]; then
  info=$(grep -E '^\s*CharacterDatabase\.Info\s*=' "$conf" | head -1 | cut -d= -f2- | tr -d '" \r')
  user=$(cut -d';' -f3 <<<"$info")
  export MYSQL_PWD; MYSQL_PWD=$(cut -d';' -f4 <<<"$info")
fi

echo "RENAME_SQL_SHA256=$(sha256sum "$sql" | cut -d' ' -f1) MAP_SHA256=$actual"
echo "CONTAINER=$container EXPECTED=$expected START=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out=$( { printf 'SET @expected_rows = %d;\n' "$expected"
         printf 'CREATE TEMPORARY TABLE rename_map (ordinal INT UNSIGNED NOT NULL, guid INT UNSIGNED NOT NULL PRIMARY KEY, old_name VARCHAR(12) NOT NULL, new_name VARCHAR(12) NOT NULL) ENGINE=MEMORY DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_general_ci;\n'
         printf 'INSERT INTO rename_map (ordinal, guid, old_name, new_name) VALUES %s;\n' "$values"
         cat "$sql"; } |
       docker exec -i ${MYSQL_PWD+-e MYSQL_PWD} "$container" mariadb -u "$user" -N -B tw_char 2>&1 ) && rc=0 || rc=$?
unset MYSQL_PWD
printf '%s\n' "$out"
echo "END=$(date -u +%Y-%m-%dT%H:%M:%SZ) CLIENT_RC=$rc"

guards=$(grep -c '^guard_.*=PASS$' <<<"$out" || true)
asserts=$(grep -c '^ASSERT_.*=PASS$' <<<"$out" || true)
fails=$(grep -c '=FAIL$' <<<"$out" || true)
if [ "$rc" -ne 0 ] || [ "$guards" -ne 9 ] || [ "$fails" -ne 0 ] || [ "$asserts" -ne 4 ]; then
  echo "RESULT=FAIL guards=$guards asserts_pass=$asserts asserts_fail=$fails"
  [ "$guards" -lt 9 ] && echo "NOTE: a guard failed -> no name was changed."
  exit 1
fi
echo "RESULT=PASS guards=$guards asserts_pass=$asserts"
