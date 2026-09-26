#!/usr/bin/env bash
# Wrapper for respec-roster.sql (twow-repo#366 A6).
#
#   run-respec-roster.sh --container <db> --csv <roster-plan.csv> --ordinals <from>-<to>
#                        --expect-guid-sha256 <hex> [--spec-index <tsv>] [--conf <mangosd.conf>] --apply
#
# Applies talent path (as specNo) and profession pair of the given ordinal range of an
# approved roster CSV to the active roster. --expect-guid-sha256 is the SHA-256 of the
# "ordinal:guid" pairs of that range (ordinal order, "," joined); run-reset-l1.sh
# --hash-from-csv prints it. A talent path missing from the spec index (e.g. "bear" before
# twow-core#308) or an unknown profession label aborts before the database is touched.
#
# Without --conf the client connects as root over the container's socket (disposable
# test databases). With --conf the CharacterDatabase credentials come from that file and
# are passed only through MYSQL_PWD; they are never printed.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sql="$here/respec-roster.sql"
spec_index="$here/premade-spec-index.tsv"
container="" csv="" ordinals="" expect_hash="" conf="" apply=""
while [ $# -gt 0 ]; do
  case $1 in
    --container) container=$2; shift 2 ;;
    --csv) csv=$2; shift 2 ;;
    --ordinals) ordinals=$2; shift 2 ;;
    --expect-guid-sha256) expect_hash=$2; shift 2 ;;
    --spec-index) spec_index=$2; shift 2 ;;
    --conf) conf=$2; shift 2 ;;
    --apply) apply=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$container" ] && [ -f "$csv" ] && [ -f "$spec_index" ] && [[ $expect_hash =~ ^[0-9a-f]{64}$ ]] &&
  [[ $ordinals =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]] && [ "${BASH_REMATCH[1]}" -le "${BASH_REMATCH[2]}" ] ||
  { echo "usage: $0 --container C --csv F --ordinals A-B --expect-guid-sha256 H [--spec-index F] [--conf F] --apply" >&2; exit 2; }
from=${BASH_REMATCH[1]} to=${BASH_REMATCH[2]} expected=$((BASH_REMATCH[2] - BASH_REMATCH[1] + 1))
[ -n "$apply" ] || { echo "refusing to run without --apply (this changes specs and professions)" >&2; exit 2; }

hash=$(awk -F, -v a="$from" -v b="$to" 'NR > 1 && $1 >= a && $1 <= b { printf "%s%s:%s", (n++ ? "," : ""), $1, $2 }' "$csv" | sha256sum | cut -d' ' -f1)
[ "$hash" = "$expect_hash" ] || { echo "CSV range $ordinals has GUID SHA-256 $hash, not the approved $expect_hash" >&2; exit 1; }

values=$(awk -F'\t' -v a="$from" -v b="$to" -v n="$expected" '
  BEGIN {
    pair["Herbalism/Alchemy"] = 1; pair["Skinning/Leatherworking"] = 2; pair["Mining/Blacksmithing"] = 3
    pair["Mining/Engineering"] = 4; pair["Mining/Jewelcrafting"] = 5; pair["Tailoring/Enchanting"] = 6
    pair["Herbalism/Mining"] = 7
  }
  FILENAME == ARGV[1] { if ($0 !~ /^#/ && NF == 3) spec[$1 " " $3] = $2 + 1; next }
  FNR == 1 { next }
  {
    split($0, f, ",")
    if (f[1] < a || f[1] > b) next
    k = f[6] " " f[8]
    if (!(k in spec)) { bad = "talent path \"" f[8] "\" of class " f[6] " is not in the spec index (ordinal " f[1] ")"; exit }
    if (!(f[10] in pair)) { bad = "unknown profession pair \"" f[10] "\" (ordinal " f[1] ")"; exit }
    printf "%s(%d,%d,%d,%d,%d)", (rows++ ? "," : ""), f[1], f[2], f[6], spec[k], pair[f[10]]
  }
  END { if (bad) { print bad > "/dev/stderr"; exit 1 } if (rows != n) { print "range has " rows " rows, expected " n > "/dev/stderr"; exit 1 } }
' "$spec_index" "$csv")

user=root
if [ -n "$conf" ]; then
  info=$(grep -E '^\s*CharacterDatabase\.Info\s*=' "$conf" | head -1 | cut -d= -f2- | tr -d '" \r')
  user=$(cut -d';' -f3 <<<"$info")
  export MYSQL_PWD; MYSQL_PWD=$(cut -d';' -f4 <<<"$info")
fi

echo "RESPEC_SQL_SHA256=$(sha256sum "$sql" | cut -d' ' -f1) SPEC_INDEX_SHA256=$(sha256sum "$spec_index" | cut -d' ' -f1) CSV_SHA256=$(sha256sum "$csv" | cut -d' ' -f1)"
echo "CONTAINER=$container SCOPE=$from-$to ROWS=$expected START=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out=$( { printf 'SET @expected_rows = %d;\nSET @expected_guid_sha256 = '\''%s'\'';\n' "$expected" "$expect_hash"
         printf 'CREATE TEMPORARY TABLE respec_plan (ordinal INT UNSIGNED NOT NULL, guid INT UNSIGNED NOT NULL PRIMARY KEY, class TINYINT UNSIGNED NOT NULL, spec_no INT UNSIGNED NOT NULL, pair TINYINT UNSIGNED NOT NULL) ENGINE=MEMORY;\n'
         printf 'INSERT INTO respec_plan (ordinal, guid, class, spec_no, pair) VALUES %s;\n' "$values"
         cat "$sql"; } |
       docker exec -i ${MYSQL_PWD+-e MYSQL_PWD} "$container" mariadb -u "$user" -N -B tw_char 2>&1 ) && rc=0 || rc=$?
unset MYSQL_PWD
printf '%s\n' "$out"
echo "END=$(date -u +%Y-%m-%dT%H:%M:%SZ) CLIENT_RC=$rc"

guards=$(grep -c '^guard_.*=PASS$' <<<"$out" || true)
asserts=$(grep -c '^ASSERT_.*=PASS$' <<<"$out" || true)
fails=$(grep -c '=FAIL$' <<<"$out" || true)
if [ "$rc" -ne 0 ] || [ "$guards" -ne 8 ] || [ "$fails" -ne 0 ] || [ "$asserts" -ne 11 ]; then
  echo "RESULT=FAIL guards=$guards asserts_pass=$asserts asserts_fail=$fails"
  [ "$guards" -lt 8 ] && echo "NOTE: a guard failed -> nothing was changed."
  exit 1
fi
echo "RESULT=PASS guards=$guards asserts_pass=$asserts"
