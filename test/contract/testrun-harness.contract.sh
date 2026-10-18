#!/usr/bin/env bash
# Contract for ops/testrun (R07a): render/diff/override/meas/report on fixtures. No Docker, no DB.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TR="$HERE/../../ops/testrun"
T=$(mktemp -d); trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

mkdir -p "$T/base" "$T/known"
cat > "$T/base/mangosd.conf" <<'EOF'
# comment = not a key
WorldDatabase.Info = "db;3306;user;pw-world-123;tw_world"
CleanupTerrain = 1
RealmID = 1
EOF
cat > "$T/base/aiplayerbot.conf" <<'EOF'
AiPlayerbot.Perf.ActionBudget = 1
AiPlayerbot.MinRandomBots = 180
EOF
cat > "$T/base/realmd.conf" <<'EOF'
LoginDatabaseInfo = "db;3306;user;pw-realm-456;tw_logon"
EOF
printf 'guild\tname\n' > "$T/roster.tsv"
cat > "$T/known/mangosd.dist" <<'EOF'
#PerformanceLog.TickStats = 0
CleanupTerrain = 1
EOF
cat > "$T/known/aiplayerbot.dist" <<'EOF'
#AiPlayerbot.ZoneExit.StrandedRescueAfter = 0
EOF
printf 'CleanupTerrain = 0\nAiPlayerbot.Perf.ActionBudget = 0\nPerformanceLog.TickStats = 1\nAiPlayerbot.ZoneExit.StrandedRescueAfter = 3\n' > "$T/live.overlay"
K=(--known "$T/known/mangosd.dist" --known "$T/known/aiplayerbot.dist")

# 1 render: in-place replace, known keys appended, deterministic hash, secrets masked, read-only output
out=$(bash "$TR/run-config.sh" render --base "$T/base" --out "$T/ref" "${K[@]}" "$T/live.overlay")
h1=$(echo "$out" | awk '{print $2}')
grep -qx 'CleanupTerrain = 0' "$T/ref/mangosd.conf" || fail "in-place replace"
[ "$(grep -c '^CleanupTerrain' "$T/ref/mangosd.conf")" = 1 ] || fail "replace must not append"
grep -qx 'PerformanceLog.TickStats = 1' "$T/ref/mangosd.conf" || fail "known mangosd key appended"
grep -qx 'AiPlayerbot.ZoneExit.StrandedRescueAfter = 3' "$T/ref/aiplayerbot.conf" || fail "known bot key appended to aiplayerbot.conf"
grep -q 'pw-' "$T/ref/keys.tsv" && fail "secret in keys.tsv"
[ "$(grep -c '<secret>' "$T/ref/keys.tsv")" = 2 ] || fail "both connection strings masked"
h2=$(bash "$TR/run-config.sh" render --base "$T/base" --out "$T/ref2" "${K[@]}" "$T/live.overlay" | awk '{print $2}')
[ "$h1" = "$h2" ] && [ ${#h1} = 64 ] || fail "hash deterministic"
[ "$(bash "$TR/run-config.sh" hash "$T/ref")" = "$h1" ] || fail "hash subcommand equals render hash"
[ -w "$T/ref/mangosd.conf" ] && [ "$(id -u)" != 0 ] && fail "render output read-only"
ok "render"

# 2 render failures: unknown key, duplicate key
printf 'Made.Up.Key = 1\n' > "$T/bad.overlay"
bash "$TR/run-config.sh" render --base "$T/base" --out "$T/r-bad" "${K[@]}" "$T/bad.overlay" 2> "$T/err" && fail "unknown key accepted"
grep -q 'UNKNOWN key Made.Up.Key' "$T/err" || fail "unknown key message"
mkdir "$T/dupbase"; cp "$T/base/"*.conf "$T/dupbase/"; echo 'RealmID = 2' >> "$T/dupbase/mangosd.conf"
bash "$TR/run-config.sh" render --base "$T/dupbase" --out "$T/r-dup" 2> "$T/err" && fail "duplicate accepted"
grep -q 'DUPLICATE key in mangosd.conf: RealmID' "$T/err" || fail "duplicate message"
ok "render rejects unknown and duplicate keys"

# 3 diff: declared vs UNDECLARED, secret values never printed
printf 'RealmID = 2\nWorldDatabase.Info = "db2;3306;user;pw-test-789;tw_world"\nLoginDatabaseInfo = "db2;3306;user;pw-test-000;tw_logon"\n' > "$T/env.overlay"
printf 'AiPlayerbot.MinRandomBots = 90\n' > "$T/arm.overlay"
bash "$TR/run-config.sh" render --base "$T/ref" --out "$T/run" --add-file "$T/roster.tsv" "$T/env.overlay" "$T/arm.overlay" > /dev/null
[ -f "$T/run/roster.tsv" ] || fail "--add-file copied"
d=$(bash "$TR/run-config.sh" diff --ref "$T/ref" --run "$T/run" --declared "$T/env.overlay" --declared "$T/arm.overlay") || fail "declared diff exit 0"
echo "$d" | grep -q 'pw-' && fail "secret printed by diff"
echo "$d" | tail -1 | grep -qx 'DIFF changed=4 undeclared=0' || fail "diff counts: $(echo "$d" | tail -1)"
set +e; d=$(bash "$TR/run-config.sh" diff --ref "$T/ref" --run "$T/run" --declared "$T/env.overlay"); rc=$?; set -e
[ $rc = 3 ] || fail "undeclared exit 3"
echo "$d" | grep -q $'^UNDECLARED\taiplayerbot.conf\tAiPlayerbot.MinRandomBots\t180\t90$' || fail "undeclared line"
ok "diff"

# 4 override: inline-map and short syntax, base mounts rewritten read-only, others untouched
cat > "$T/compose.yml" <<EOF
services:
  mangosd:
    volumes:
      - { type: bind, source: "$T/base/mangosd.conf", target: /opt/turtle/etc/mangosd.conf, read_only: true }
      - '$T/base/aiplayerbot.conf:/opt/turtle/etc/aiplayerbot.conf'
      - '$T/logs:/var/log/turtle'
  realmd:
    volumes:
      - '$T/base/realmd.conf:/opt/turtle/etc/realmd.conf:ro'
EOF
bash "$TR/run-config.sh" override --run "$T/run" --like "$T/compose.yml" --base "$T/base" -o "$T/ov.yml" > /dev/null
[ "$(grep -c 'read_only: true' "$T/ov.yml")" = 3 ] || fail "three read-only mounts"
grep -q 'target: /opt/turtle/etc/realmd.conf' "$T/ov.yml" && grep -q '^  realmd:' "$T/ov.yml" || fail "realmd service mount"
grep -q '/var/log/turtle' "$T/ov.yml" && fail "non-config mount rewritten"
grep -q "$T/base" "$T/ov.yml" && fail "base still mounted"
ok "override"

# 5 meas + report: DISKLOAD overlap makes a perf window invalid, behaviour window stays valid
RT_ROOT="$T/root"; mkdir -p "$RT_ROOT/flags"; : > "$RT_ROOT/threads.out"; RT_PSI_DIR="$T/psi"; mkdir -p "$RT_PSI_DIR"
export RT_ROOT RT_PSI_DIR
# shellcheck source=../../ops/testrun/meas.sh
. "$TR/meas.sh"
RT_SLOT=202610211415-demo; RT_ARM=ctl; RT_RUNCFG=$h1; RT_IMG=abc123; export RT_SLOT RT_ARM RT_RUNCFG RT_IMG
meas_start 0 125 v8; MEAS_FROM=$(date -u -d '-30 min' +%FT%TZ); MEAS_HEAD="slot=$RT_SLOT arm=$RT_ARM class=perf reset=125 roster=v8 img=abc123 cfg=${h1:0:12}"
echo "DISKLOAD cli-x $(date -u -d '-20 min' +%FT%H:%M)-$(date -u -d '-10 min' +%FT%H:%M)" >> "$RT_ROOT/threads.out"
RT_CLASS=perf; export RT_CLASS MEAS_FROM MEAS_HEAD; meas_end && fail "perf window with DISKLOAD must be invalid"
grep -q '^MEAS end .*isolated=no valid=0 reason=not-isolated' "$RT_ROOT/threads.out" || fail "perf end line"
RT_ARM=abc; RT_CLASS=behav; meas_start 0; MEAS_FROM=$(date -u -d '-30 min' +%FT%TZ); MEAS_HEAD="slot=$RT_SLOT arm=abc class=behav reset=126 roster=v8 img=abc123 cfg=${h1:0:12}"; export RT_CLASS MEAS_FROM MEAS_HEAD
meas_end || fail "behaviour window stays valid"
printf '%s 60\n' "$RT_SLOT" > "$T/planned.tsv"
r=$(bash "$TR/report.sh" --threads "$RT_ROOT/threads.out" --planned "$T/planned.tsv")
echo "$r" | grep -q $'^SLOT\t202610211415-demo\t60\t60\t30\t50%\t2\t2\t1$' || fail "slot line: $(echo "$r" | grep SLOT)"
echo "$r" | grep -q $'^WEEK\t2026-W43\t60\t30\t50%$' || fail "week line: $(echo "$r" | grep WEEK)"
echo "$r" | grep -q $'^A2\t2/2 ' || fail "A2"
ok "meas + report"
echo "testrun-harness contract: all ok"
