#!/usr/bin/env bash
# Wrapper for talent-reset.sql (twow-repo#366, #357): at_login |= 4 for the roster bots of one
# class whose specNo is in a list, e.g. every shaman on 7.1 (specNo 2) or 7.3 (specNo 4) after
# a deploy that changes their premade links or adds path auras.
#
#   run-talent-reset.sh --container <db> --class <n> --spec-nos <a,b,...> --dry-run [--conf F]
#   run-talent-reset.sh --container <db> --class <n> --spec-nos <a,b,...> --expected <n> \
#                       --expect-guid-sha256 <hex> [--conf F] --apply
#
# The dry run is read-only and prints TARGETS=, GUID_SHA256= and ORDINALS=; the apply must
# repeat exactly that count and hash. Without --conf the client connects as root over the
# container's socket (disposable test databases); with --conf the CharacterDatabase
# credentials come from that file and travel only through MYSQL_PWD.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sql="$here/talent-reset.sql"
container="" cls="" specs="" expected="" expect_hash="" conf="" mode=""
while [ $# -gt 0 ]; do
  case $1 in
    --container) container=$2; shift 2 ;;
    --class) cls=$2; shift 2 ;;
    --spec-nos) specs=$2; shift 2 ;;
    --expected) expected=$2; shift 2 ;;
    --expect-guid-sha256) expect_hash=$2; shift 2 ;;
    --conf) conf=$2; shift 2 ;;
    --dry-run) mode=dry; shift ;;
    --apply) mode=apply; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$container" ] && [[ $cls =~ ^[1-9][0-9]?$ ]] && [[ $specs =~ ^[1-9][0-9]?(,[1-9][0-9]?)*$ ]] && [ -n "$mode" ] ||
  { echo "usage: $0 --container C --class N --spec-nos A,B (--dry-run | --expected N --expect-guid-sha256 H --apply) [--conf F]" >&2; exit 2; }
if [ "$mode" = apply ]; then
  [[ $expected =~ ^[1-9][0-9]*$ ]] && [[ $expect_hash =~ ^[0-9a-f]{64}$ ]] ||
    { echo "--apply needs --expected and --expect-guid-sha256 from the dry run" >&2; exit 2; }
fi

user=root
if [ -n "$conf" ]; then
  info=$(grep -E '^\s*CharacterDatabase\.Info\s*=' "$conf" | head -1 | cut -d= -f2- | tr -d '" \r')
  user=$(cut -d';' -f3 <<<"$info")
  export MYSQL_PWD; MYSQL_PWD=$(cut -d';' -f4 <<<"$info")
fi

echo "TALENT_RESET_SQL_SHA256=$(sha256sum "$sql" | cut -d' ' -f1)"
echo "CONTAINER=$container CLASS=$cls SPEC_NOS=$specs MODE=$mode START=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
header=$(printf "SET @class = %d;\nSET @spec_list = '%s';\nSET @expected_targets = %d;\nSET @expected_guid_sha256 = '%s';\n" \
  "$cls" "$specs" "${expected:-0}" "${expect_hash:-none}")
if [ "$mode" = dry ]; then
  body=$(sed '/^-- -* guards$/,$d' "$sql")
else
  body=$(cat "$sql")
fi
out=$(printf '%s\n%s\n' "$header" "$body" | docker exec -i ${MYSQL_PWD+-e MYSQL_PWD} "$container" mariadb -u "$user" -N -B tw_char 2>&1) && rc=0 || rc=$?
unset MYSQL_PWD
printf '%s\n' "$out"
echo "END=$(date -u +%Y-%m-%dT%H:%M:%SZ) CLIENT_RC=$rc"
if [ "$mode" = dry ]; then
  [ "$rc" -eq 0 ] && grep -q '^TARGETS=' <<<"$out" && { echo "RESULT=DRY_RUN (nothing changed)"; exit 0; }
  echo "RESULT=FAIL (dry run)"; exit 1
fi

guards=$(grep -c '^guard_.*=PASS$' <<<"$out" || true)
asserts=$(grep -c '^ASSERT_.*=PASS$' <<<"$out" || true)
fails=$(grep -c '=FAIL$' <<<"$out" || true)
if [ "$rc" -ne 0 ] || [ "$guards" -ne 4 ] || [ "$fails" -ne 0 ] || [ "$asserts" -ne 4 ]; then
  echo "RESULT=FAIL guards=$guards asserts_pass=$asserts asserts_fail=$fails"
  [ "$guards" -lt 4 ] && echo "NOTE: a guard failed -> nothing was changed."
  exit 1
fi
echo "RESULT=PASS guards=$guards asserts_pass=$asserts"
