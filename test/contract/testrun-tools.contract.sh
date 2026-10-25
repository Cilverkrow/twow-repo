#!/usr/bin/env bash
# Contract for ops/testrun/tickmed.sh and ops/testrun/routetime.awk (PATH-02 §4.4, twow-repo#592): fixtures only, no Docker, no DB.
# Runs with the default awk of the runner (mawk on Debian/Ubuntu) and, when installed, with gawk too.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TR="$HERE/../../ops/testrun"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# perf.log style, 12 minutes; the first two lines are outside the window used below
for m in 00 01 02 03 04 05 06 07 08 09 10 11; do
  p95=$((60 + 10#$m)); o100=$((10#$m % 3))
  echo "2026-10-21 18:$m:39 Tick stats: interval=60s ticks=11$m p50=31ms p95=${p95}ms p99=74ms max=148ms over100=$o100 over200=0 over20=1136 over50=147"
done > "$T/perf.log"
echo "2026-10-21 18:05:40 something else p95=999ms" >> "$T/perf.log"

# 1 tickmed: last 10 lines, units dropped, median [min-max]
out=$(bash "$TR/tickmed.sh" "$T/perf.log")
echo "$out" | grep -q '^TICKMED n=10 first=2026-10-21T18:02:39 last=2026-10-21T18:11:39 ' || fail "tickmed head: $out"
echo "$out" | grep -q ' p95=66.5\[62-71\] ' || fail "tickmed p95 median of 62..71: $out"
echo "$out" | grep -q ' over100=1\[0-2\] ' || fail "tickmed over100: $out"
echo "$out" | grep -q ' ticks=1106.5\[1102-1111\] ' || fail "tickmed ticks: $out"
# window (ISO bounds, minute precision inclusive) and N=0 = all lines of the window
out=$(bash "$TR/tickmed.sh" "$T/perf.log" 0 2026-10-21T18:03 2026-10-21T18:05)
echo "$out" | grep -q '^TICKMED n=3 first=2026-10-21T18:03:39 last=2026-10-21T18:05:39 .* p95=64\[63-65\] ' || fail "tickmed window: $out"
# docker -t style ISO prefix
sed 's/^2026-10-21 \(..:..:..\)/2026-10-21T\1.123456Z/' "$T/perf.log" > "$T/docker.log"
out=$(bash "$TR/tickmed.sh" "$T/docker.log" 3)
echo "$out" | grep -q '^TICKMED n=3 first=2026-10-21T18:09:39 last=2026-10-21T18:11:39 ' || fail "tickmed docker log: $out"
if bash "$TR/tickmed.sh" "$T/perf.log" 10 2026-10-22T00:00 2026-10-22T01:00 > /dev/null; then fail "empty window must exit 1"; fi
ok "tickmed"

# [RouteTime] lines: old image (no diag fields) and new image (dispatches + level bands), plus [WorldBots] and [RoutePrecheck]
cat > "$T/mangosd.log" <<'EOF'
2026-10-21 18:00:00 [RouteTime] builds=2 ms=116 ge16=2 ge33=1 ge50=1 ge100=1 max_ms=100 direct_ms=6 astar_ms=20 endleg_ms=60 startleg_ms=7 step_max_us=15000 dsteps_ok=0:0,1:1,2:0,4:0,8:0,16:0,40:0 dsteps_fail=0:0,1:0,2:0,4:1,8:0,16:0,40:0 dispatch_n=2 dispatch_ms=2 dispatch_max_us=1500 ok=1 fail=1 nodes_ms=0 hearth_ms=2 build_ms=0 lock_ms=0 step_max_ge12=1 astar_max_ge12=1 pf=41
2026-10-21 18:01:00 [RouteTime] builds=4 ms=50 ge16=1 ge33=0 ge50=0 ge100=0 max_ms=20 direct_ms=6 astar_ms=20 endleg_ms=10 startleg_ms=7 step_max_us=900 dsteps_ok=0:0,1:3,2:0,4:0,8:0,16:0,40:0 dsteps_fail=0:0,1:0,2:0,4:1,8:0,16:0,40:0 dispatch_n=10 dispatch_ms=4 dispatch_max_us=700 ok=3 fail=1 nodes_ms=0 hearth_ms=0 build_ms=0 lock_ms=0 step_max_ge12=0 astar_max_ge12=0 pf=12 dispatches=12 new_target=3 repath=6 retry=2 follow=1 lv0=0/0/0/0/0/0 lv1=1/5/0/0/4/1 lv20=0/0/0/0/0/0 lv40=3/45/0/0/6/3
2026-10-21 18:01:05 [WorldBots] logins=0 online=540
2026-10-21 18:01:06 [RoutePrecheck] level=1 target_checks=7 early_skips=2
2026-10-21 18:02:00 [RouteTime] builds=6 ms=300 ge16=3 ge33=2 ge50=1 ge100=1 max_ms=150 direct_ms=6 astar_ms=20 endleg_ms=10 startleg_ms=7 step_max_us=900 dsteps_ok=0:0,1:3,2:0,4:0,8:0,16:0,40:0 dsteps_fail=0:0,1:0,2:0,4:1,8:0,16:0,40:0 dispatch_n=8 dispatch_ms=6 dispatch_max_us=700 ok=5 fail=1 nodes_ms=0 hearth_ms=0 build_ms=0 lock_ms=0 step_max_ge12=0 astar_max_ge12=0 pf=12 dispatches=9 new_target=1 repath=5 retry=3 follow=0 lv0=1/0/0/0/0/0 lv1=0/0/0/0/2/1 lv20=0/0/0/0/0/0 lv40=5/300/2/1/6/5
2026-10-21 18:02:05 [WorldBots] logins=2 online=538
EOF
for A in awk gawk; do
  command -v "$A" > /dev/null || continue
  out=$("$A" -f "$TR/routetime.awk" "$T/mangosd.log")
  echo "$out" | grep -q '^ROUTETIME lines=3 first=2026-10-21T18:00:00 last=2026-10-21T18:02:00$' || fail "$A routetime head: $(echo "$out" | head -1)"
  echo "$out" | grep -q $'^ms\t3\t466\t116\t50\t300$' || fail "$A ms sum/median/min/max"
  echo "$out" | grep -q $'^dsteps_ok.1\t3\t7\t3\t1\t3$' || fail "$A step class field"
  echo "$out" | grep -q $'^dispatches\t2\t21\t10.5\t9\t12$' || fail "$A dispatches only in the diag lines"
  echo "$out" | grep -q $'^lv40.ms\t2\t345\t172.5\t45\t300$' || fail "$A level band field"
  echo "$out" | grep -q $'^precheck.early_skips\t1\t2\t2\t2\t2$' || fail "$A precheck prefix"
  echo "$out" | grep -q $'^worldbots.online\t2\t1078\t539\t538\t540$' || fail "$A worldbots"
  row=$("$A" -v row=1 -f "$TR/routetime.awk" "$T/mangosd.log")
  [ "$row" = "PATHROW lines=3 builds=12 ms=466 ge33=3 ge100=2 fail=3 dispatch_n=20 dispatch_ms=12 dispatches=21 new_target=4 repath=11 retry=5 follow=1 lv1=1/5/0/0/6/2 lv20=0/0/0/0/0/0 lv40=8/345/2/1/12/8 online_med=539" ] \
    || fail "$A row: $row"
  row=$("$A" -v row=1 -v from=2026-10-21T18:00 -v to="2026-10-21 18:00" -f "$TR/routetime.awk" "$T/mangosd.log")
  [ "$row" = "PATHROW lines=1 builds=2 ms=116 ge33=1 ge100=1 fail=1 dispatch_n=2 dispatch_ms=2 dispatches=- new_target=- repath=- retry=- follow=- lv1=- lv20=- lv40=- online_med=-" ] \
    || fail "$A old-image window row: $row"
  if "$A" -v from=2026-10-22 -f "$TR/routetime.awk" "$T/mangosd.log" > /dev/null; then fail "$A empty window must exit 1"; fi
  ok "routetime.awk with $A"
done
echo "testrun-tools contract: all ok"
