#!/usr/bin/env bash
# R07a acceptance report from the harness lines in threads.out (no host or DB access).
#   report.sh --threads FILE --planned FILE [--from YYYYMMDDHHMM] [--to YYYYMMDDHHMM]
# planned FILE: "<slot> <planned-minutes>" per line (slot = YYYYMMDDHHMM-name).
# Output (TSV):
#   SLOT  slot planned_min measured_min valid_min valid_pct arms arms_with_cfg arms_valid
#   WEEK  YYYY-Www planned_min valid_min valid_pct
#   A1    starts_with_cfg/arm_ups (rendered + hashed before start)
#   A2    meas_lines_with_cfg/meas_lines
#   A3    undeclared deviations (RT FAIL … undeclared)
#   A4    base mounted or not read-only (RT FAIL … verify)
set -euo pipefail
th="" pl="" from=000000000000 to=999999999999
while [ $# -gt 0 ]; do case $1 in
    --threads) th=$2; shift 2;; --planned) pl=$2; shift 2;; --from) from=$2; shift 2;; --to) to=$2; shift 2;;
    *) echo "report: unknown argument $1" >&2; exit 2;; esac; done
[ -f "$th" ] && [ -f "$pl" ] || { echo "report: --threads and --planned needed" >&2; exit 2; }

res=$(awk -v from="$from" -v to="$to" '
    function kv(k,   r) { r = ""; if (match($0, " " k "=[^ ]*")) r = substr($0, RSTART + length(k) + 2, RLENGTH - length(k) - 2); return r }
    FNR == NR { if (substr($1,13,1) == "-" && substr($1,1,12) ~ /^[0-9]+$/ && substr($1,1,12) >= from && substr($1,1,12) <= to) { plan[$1] = $2 + 0; seen[$1] = 1 } next }
    /^RT arm .* up cfg=/ { split($3, a, "/"); ups[a[1]]++; if (kv("cfg") != "" && kv("cfg") != "-") upcfg[a[1]]++; tot_up++; if (kv("cfg") != "") tot_upcfg++; next }
    /^RT FAIL / { if ($0 ~ /undeclared/) undecl++; if ($0 ~ /verify/) vfail++; next }
    /^MEAS end / {
        s = kv("slot"); if (!(s in seen)) { if (substr(s,1,12) < from || substr(s,1,12) > to) next; seen[s] = 1 }
        meas[s] += kv("min"); arms[s]++; nlines++
        c = kv("cfg"); if (c != "" && c !~ /-$/) { armcfg[s]++; ncfg++ }
        if (kv("valid") == "1") { valid[s] += kv("min"); armvalid[s]++ }
    }
    END {
        n = 0; for (s in seen) order[++n] = s
        for (i = 2; i <= n; i++) { x = order[i]; for (j = i - 1; j >= 1 && order[j] > x; j--) order[j+1] = order[j]; order[j+1] = x }
        for (i = 1; i <= n; i++) {
            s = order[i]; p = plan[s] + 0; v = valid[s] + 0
            printf "SLOT\t%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\n", s, p, meas[s], v, (p > 0 ? sprintf("%.0f%%", 100 * v / p) : "-"), arms[s], armcfg[s], armvalid[s]
        }
        printf "A1\t%d/%d arm starts rendered+hashed before start\n", tot_upcfg, tot_up
        printf "A2\t%d/%d measurement lines with cfg\n", ncfg, nlines
        printf "A3\t%d undeclared deviations\n", undecl
        printf "A4\t%d verify failures (base mounted / not read-only / changed)\n", vfail
    }' "$pl" "$th")
printf '%s\n' "$res" | grep '^SLOT' || true
# ISO week per slot via date (GNU), then summed
printf '%s\n' "$res" | awk -F'\t' '$1=="SLOT"{print substr($2,1,8) "\t" $3 "\t" $5}' | while IFS=$'\t' read -r d p v; do
    printf '%s\t%s\t%s\n' "$(date -u -d "$d 12:00" +%G-W%V)" "$p" "$v"; done |
    awk -F'\t' '{ p[$1] += $2; v[$1] += $3 } END { for (w in p) printf "WEEK\t%s\t%d\t%d\t%s\n", w, p[w], v[w], (p[w] > 0 ? sprintf("%.0f%%", 100 * v[w] / p[w]) : "-") }' | sort
printf '%s\n' "$res" | grep '^A[0-9]' || true
