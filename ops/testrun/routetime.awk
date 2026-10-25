# [RouteTime] window summary (PATH-02 §4.4, twow-repo#592; pure text, mawk and gawk).
#   awk -f routetime.awk [-v from=TIME] [-v to=TIME] [-v row=1] LOG...
# LOG    mangosd log(s) with the minute lines of AiPlayerbot.Perf.RouteTimeTrace ("[RouteTime] builds=... ms=... ge33=...") and,
#        if present, [WorldBots] (logins= online=) and [RoutePrecheck]; the line starts with its time ("2026-10-21 18:19:39" or ISO).
# from/to  UTC "YYYY-MM-DD HH:MM[:SS]" or with "T", inclusive on the given precision (default: everything).
# Fields: every key=number of a [RouteTime] line; "a:b,c:d" (dsteps_ok/dsteps_fail) becomes key.a; the level bands
#   lv0/lv1/lv20/lv40 = builds/ms/ge33/ge100/dispatch_n/dispatch_ms become lvX.builds ... lvX.dispatch_ms; [RoutePrecheck] fields get
#   the prefix "precheck.", [WorldBots] logins/online the prefix "worldbots.".
# Output (default): "ROUTETIME lines=<n> first= last=" and per field "<field>\tn\tsum\tmedian\tmin\tmax" (per minute line).
# row=1: one line for a run report, sums over the window plus the median of worldbots.online:
#   "PATHROW lines= builds= ms= ge33= ge100= fail= dispatch_n= dispatch_ms= dispatches= new_target= repath= retry= follow=
#    lv1=builds/ms/ge33/ge100/dispatch_n/dispatch_ms lv20=... lv40=... online_med="
# Lines without the PATH-02 diag fields (older images) simply have no dispatches=/lvX fields; row=1 prints "-" for them.
function addv(key, v) {
  if (!(key in cnt)) order[++nk] = key
  cnt[key]++; sum[key] += v; vals[key] = vals[key] " " v
  if (!(key in mn) || v < mn[key]) mn[key] = v
  if (!(key in mx) || v > mx[key]) mx[key] = v
}
function med(s,   a, m, i, j, x) {
  m = split(substr(s, 2), a, " ")
  for (i = 2; i <= m; i++) { x = a[i] + 0; for (j = i - 1; j >= 1 && a[j] + 0 > x; j--) a[j + 1] = a[j]; a[j + 1] = x }
  return (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
}
function inwin(   t) {
  t = substr($0, 1, 19); sub(/T/, " ", t)
  return t >= flo && substr(t, 1, length(fhi)) <= fhi
}
function fields(prefix, start,   i, kv, k, v, parts, np, p, sub2, nb) {
  for (i = start; i <= NF; i++) {
    if (split($i, kv, "=") != 2) continue
    k = kv[1]; v = kv[2]
    if (v ~ /^-?[0-9.]+$/) { addv(prefix k, v + 0); continue }
    if (k ~ /^lv[0-9]+$/ && split(v, parts, "/") == 6) {
      nb = split("builds ms ge33 ge100 dispatch_n dispatch_ms", bn, " ")
      for (p = 1; p <= nb; p++) addv(prefix k "." bn[p], parts[p] + 0)
      continue
    }
    if (v ~ /:/) {
      np = split(v, parts, ",")
      for (p = 1; p <= np; p++) if (split(parts[p], sub2, ":") == 2) addv(prefix k "." sub2[1], sub2[2] + 0)
      continue
    }
    if (v ~ /\//) { np = split(v, parts, "/"); for (p = 1; p <= np; p++) addv(prefix k "." p, parts[p] + 0) }
  }
}
function tag(name,   i) { for (i = 1; i <= NF; i++) if ($i == name) return i; return 0 }
function s(key) { return (key in sum) ? sum[key] : "-" }
function band(b) {
  if (!((b ".builds") in sum)) return "-"
  return sum[b ".builds"] "/" sum[b ".ms"] "/" sum[b ".ge33"] "/" sum[b ".ge100"] "/" sum[b ".dispatch_n"] "/" sum[b ".dispatch_ms"]
}
BEGIN {
  flo = (from == "") ? "0000" : from; fhi = (to == "") ? "9999" : to
  sub(/T/, " ", flo); sub(/T/, " ", fhi)
}
/\[RouteTime\] / && inwin() { i = tag("[RouteTime]"); lines++; tt = substr($0, 1, 19); sub(/T/, " ", tt); if (lines == 1) first = tt; last = tt; fields("", i + 1); next }
/\[RoutePrecheck\] / && inwin() { fields("precheck.", tag("[RoutePrecheck]") + 1); next }
/\[WorldBots\] / && inwin() { i = tag("[WorldBots]"); for (j = i + 1; j <= NF; j++) if ($j ~ /^(logins|online)=[0-9]+$/) { split($j, kv, "="); addv("worldbots." kv[1], kv[2] + 0) } }
END {
  gsub(/ /, "T", first); gsub(/ /, "T", last)
  if (row) {
    printf "PATHROW lines=%d builds=%s ms=%s ge33=%s ge100=%s fail=%s dispatch_n=%s dispatch_ms=%s dispatches=%s new_target=%s repath=%s retry=%s follow=%s lv1=%s lv20=%s lv40=%s online_med=%s\n",
      lines, s("builds"), s("ms"), s("ge33"), s("ge100"), s("fail"), s("dispatch_n"), s("dispatch_ms"), s("dispatches"), s("new_target"),
      s("repath"), s("retry"), s("follow"), band("lv1"), band("lv20"), band("lv40"), ("worldbots.online" in vals) ? med(vals["worldbots.online"]) : "-"
    exit (lines ? 0 : 1)
  }
  print "ROUTETIME lines=" lines " first=" first " last=" last
  for (i = 1; i <= nk; i++) { k = order[i]; printf "%s\t%d\t%s\t%s\t%s\t%s\n", k, cnt[k], sum[k], med(vals[k]), mn[k], mx[k] }
  exit (lines ? 0 : 1)
}
