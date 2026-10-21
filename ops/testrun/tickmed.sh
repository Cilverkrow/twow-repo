#!/usr/bin/env bash
# Median [min-max] of the core "Tick stats" minute lines over a window (PATH-02 §4.4, twow-repo#592; no host or DB access).
#   tickmed.sh FILE [N] [FROM] [TO]
# FILE   perf.log ("2026-10-21 18:19:39 Tick stats: interval=60s ticks=1166 p50=31ms ...") or a mangosd/docker log with the same
#        line after an ISO time ("2026-10-21T18:19:39.123Z ...").
# N      the last N lines of the window (default 10, the tail-metric rule: medians over >= 10 one-minute windows); 0 = all lines.
# FROM/TO  UTC "YYYY-MM-DD HH:MM[:SS]" or "YYYY-MM-DDTHH:MM[:SS]", inclusive on the given precision (default: the whole file).
# Output, one line:
#   TICKMED n=<lines> first=<time> last=<time> ticks=M[min-max] p50=... p95=... p99=... max=... over20=... over50=... over100=... over200=...
# Units (ms, s) are dropped; a field missing from every line is left out. Exit 1 when the window holds no line.
set -euo pipefail
f=${1:?usage: tickmed.sh FILE [N] [FROM] [TO]}; n=${2:-10}; lo=${3:-0000}; hi=${4:-9999}
[ -r "$f" ] || { echo "tickmed: cannot read $f" >&2; exit 2; }
[[ "$n" =~ ^[0-9]+$ ]] || { echo "tickmed: N must be a number" >&2; exit 2; }
lo=${lo/T/ }; hi=${hi/T/ }
grep -F 'Tick stats:' "$f" \
  | awk -v lo="$lo" -v hi="$hi" '{ t = substr($0, 1, 19); sub(/T/, " ", t) } t >= lo && substr(t, 1, length(hi)) <= hi' \
  | { if [ "$n" -gt 0 ]; then tail -n "$n"; else cat; fi; } \
  | awk '
function med(s,   a, m, i, j, x) {   # s = " v1 v2 ..."; insertion sort (mawk has no asort)
  m = split(substr(s, 2), a, " ")
  for (i = 2; i <= m; i++) { x = a[i] + 0; for (j = i - 1; j >= 1 && a[j] + 0 > x; j--) a[j + 1] = a[j]; a[j + 1] = x }
  lo_ = a[1]; hi_ = a[m]
  return (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
}
{ t = substr($0, 1, 19); sub(/T/, " ", t); if (NR == 1) first = t; last = t
  for (i = 1; i <= NF; i++) if (split($i, kv, "=") == 2) { v = kv[2]; sub(/(ms|s)$/, "", v); if (v ~ /^[0-9.]+$/) vals[kv[1]] = vals[kv[1]] " " v } }
END {
  if (NR == 0) { print "TICKMED n=0"; exit 1 }
  gsub(/ /, "T", first); gsub(/ /, "T", last)
  out = "TICKMED n=" NR " first=" first " last=" last
  k = split("ticks p50 p95 p99 max over20 over50 over100 over200", keys, " ")
  for (i = 1; i <= k; i++) if (keys[i] in vals) { mv = med(vals[keys[i]]); out = out " " keys[i] "=" mv "[" lo_ "-" hi_ "]" }
  print out
}'
