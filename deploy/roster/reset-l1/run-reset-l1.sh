#!/usr/bin/env bash
# Wrapper for reset-l1.sql (twow-repo#334). See README.md in this directory.
#
#   run-reset-l1.sh --container <db-container> --expected <n> [--conf <mangosd.conf>] --apply
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
container="" expected="" conf="" apply=""
while [ $# -gt 0 ]; do
  case $1 in
    --container) container=$2; shift 2 ;;
    --expected) expected=$2; shift 2 ;;
    --conf) conf=$2; shift 2 ;;
    --apply) apply=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$container" ] && [[ $expected =~ ^[1-9][0-9]*$ ]] || { echo "usage: $0 --container C --expected N [--conf F] --apply" >&2; exit 2; }
[ -n "$apply" ] || { echo "refusing to run without --apply (this mutates tw_char and has no rollback)" >&2; exit 2; }

user=root
if [ -n "$conf" ]; then
  info=$(grep -E '^\s*CharacterDatabase\.Info\s*=' "$conf" | head -1 | cut -d= -f2- | tr -d '" \r')
  user=$(cut -d';' -f3 <<<"$info")
  export MYSQL_PWD; MYSQL_PWD=$(cut -d';' -f4 <<<"$info")
fi

echo "RESET_SQL_SHA256=$(sha256sum "$sql" | cut -d' ' -f1)"
echo "CONTAINER=$container EXPECTED=$expected START=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out=$( { printf 'SET @expected_targets = %d;\n' "$expected"; cat "$sql"; } |
       docker exec -i ${MYSQL_PWD+-e MYSQL_PWD} "$container" mariadb -u "$user" -N -B tw_char 2>&1 ) && rc=0 || rc=$?
unset MYSQL_PWD
printf '%s\n' "$out"
echo "END=$(date -u +%Y-%m-%dT%H:%M:%SZ) CLIENT_RC=$rc"

guards=$(grep -c '^guard_.*=PASS$' <<<"$out" || true)
asserts=$(grep -c '^ASSERT_.*=PASS$' <<<"$out" || true)
fails=$(grep -c '=FAIL$' <<<"$out" || true)
if [ "$rc" -ne 0 ] || [ "$guards" -ne 7 ] || [ "$fails" -ne 0 ] || [ "$asserts" -lt 23 ]; then
  echo "RESULT=FAIL guards=$guards asserts_pass=$asserts asserts_fail=$fails"
  [ "$guards" -lt 7 ] && echo "NOTE: a guard failed -> no mutation was executed."
  exit 1
fi
echo "RESULT=PASS guards=$guards asserts_pass=$asserts"
