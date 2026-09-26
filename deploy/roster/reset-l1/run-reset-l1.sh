#!/usr/bin/env bash
# Wrapper for reset-l1.sql (twow-repo#334, target scope #366). See README.md.
#
#   run-reset-l1.sh --container <db-container> --expected <n> [--conf <mangosd.conf>]
#                   [--ordinals <from>-<to> --expect-guid-sha256 <hex>] --apply
#   run-reset-l1.sh --hash-from-csv <roster.csv> --ordinals <from>-<to>
#
# Without --ordinals the whole active roster is the target (the #334 behaviour).
# With --ordinals only those members are reset; --expect-guid-sha256 is then
# mandatory and must equal the SHA-256 of "ordinal:guid" pairs (ordinal order,
# joined by ","), which --hash-from-csv computes from an approved roster CSV.
#
# Without --conf the client connects as root over the container's socket (disposable
# test databases). With --conf the CharacterDatabase credentials are read from that
# file and passed only through MYSQL_PWD; they are never printed.
#
# The client runs in batch mode and stops at the first error, so a failing guard
# (CHECK constraint on reset_guard) aborts before the first mutation. Exit code 0
# only if every guard and every assert reports PASS.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sql="$here/reset-l1.sql"
container="" expected="" conf="" apply="" ordinals="" expect_hash="" hash_csv=""
while [ $# -gt 0 ]; do
  case $1 in
    --container) container=$2; shift 2 ;;
    --expected) expected=$2; shift 2 ;;
    --conf) conf=$2; shift 2 ;;
    --ordinals) ordinals=$2; shift 2 ;;
    --expect-guid-sha256) expect_hash=$2; shift 2 ;;
    --hash-from-csv) hash_csv=$2; shift 2 ;;
    --apply) apply=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

scope_from=1 scope_to=4294967295
if [ -n "$ordinals" ]; then
  [[ $ordinals =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] ||
    { echo "--ordinals must be <from>-<to> with 1 <= from <= to" >&2; exit 2; }
  scope_from=${BASH_REMATCH[1]} scope_to=${BASH_REMATCH[2]}
fi

if [ -n "$hash_csv" ]; then
  [ -n "$ordinals" ] || { echo "--hash-from-csv needs --ordinals" >&2; exit 2; }
  awk -F, -v a="$scope_from" -v b="$scope_to" 'NR > 1 && $1 >= a && $1 <= b { printf "%s%s:%s", (n++ ? "," : ""), $1, $2 }' "$hash_csv" |
    sha256sum | cut -d' ' -f1
  exit 0
fi

[ -n "$container" ] && [[ $expected =~ ^[1-9][0-9]*$ ]] ||
  { echo "usage: $0 --container C --expected N [--conf F] [--ordinals A-B --expect-guid-sha256 H] --apply" >&2; exit 2; }
if [ -n "$ordinals" ]; then
  [[ $expect_hash =~ ^[0-9a-f]{64}$ ]] || { echo "--ordinals requires --expect-guid-sha256 <64 lowercase hex>" >&2; exit 2; }
  [ $((scope_to - scope_from + 1)) -eq "$expected" ] || { echo "--expected must equal the ordinal range size" >&2; exit 2; }
elif [ -n "$expect_hash" ]; then
  echo "--expect-guid-sha256 is only valid together with --ordinals" >&2; exit 2
fi
[ -n "$apply" ] || { echo "refusing to run without --apply (this mutates tw_char and has no rollback)" >&2; exit 2; }

user=root
if [ -n "$conf" ]; then
  info=$(grep -E '^\s*CharacterDatabase\.Info\s*=' "$conf" | head -1 | cut -d= -f2- | tr -d '" \r')
  user=$(cut -d';' -f3 <<<"$info")
  export MYSQL_PWD; MYSQL_PWD=$(cut -d';' -f4 <<<"$info")
fi

hash_sql=NULL
[ -n "$expect_hash" ] && hash_sql="'$expect_hash'"
echo "RESET_SQL_SHA256=$(sha256sum "$sql" | cut -d' ' -f1)"
echo "CONTAINER=$container EXPECTED=$expected SCOPE=$scope_from-$scope_to START=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out=$( { printf 'SET @expected_targets = %d;\nSET @scope_from = %d;\nSET @scope_to = %d;\nSET @expected_guid_sha256 = %s;\n' \
           "$expected" "$scope_from" "$scope_to" "$hash_sql"; cat "$sql"; } |
       docker exec -i ${MYSQL_PWD+-e MYSQL_PWD} "$container" mariadb -u "$user" -N -B tw_char 2>&1 ) && rc=0 || rc=$?
unset MYSQL_PWD
printf '%s\n' "$out"
echo "END=$(date -u +%Y-%m-%dT%H:%M:%SZ) CLIENT_RC=$rc"

guards=$(grep -c '^guard_.*=PASS$' <<<"$out" || true)
asserts=$(grep -c '^ASSERT_.*=PASS$' <<<"$out" || true)
fails=$(grep -c '=FAIL$' <<<"$out" || true)
if [ "$rc" -ne 0 ] || [ "$guards" -ne 8 ] || [ "$fails" -ne 0 ] || [ "$asserts" -lt 23 ]; then
  echo "RESULT=FAIL guards=$guards asserts_pass=$asserts asserts_fail=$fails"
  [ "$guards" -lt 8 ] && echo "NOTE: a guard failed -> no mutation was executed."
  exit 1
fi
echo "RESULT=PASS guards=$guards asserts_pass=$asserts"
