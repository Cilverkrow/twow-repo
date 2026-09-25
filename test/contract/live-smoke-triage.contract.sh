#!/usr/bin/env bash
# Pure contract checks for the live-smoke error triage (#36): no Docker daemon,
# database, or live server is contacted. Synthetic server logs only.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
smoke="$root/ops/live/live-smoke.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
count() { awk -F'\t' -v k="$2" '$1==k{print $2}' <<<"$1"; }

base="$tmp/base.log"
cat > "$base" <<'LOG'
2026-09-25 14:21:10 Using configuration file /opt/turtle/etc/mangosd.conf
2026-09-25 14:21:30 ERROR:Table creature_movement contain path for creature guid 123, but this creature guid does not exist. Skipping.
2026-09-25 14:21:31 ERROR:Item (Entry: 4567) has wrong (not existing) spell category in spellcategory_1 (89)
2026-09-25 14:23:02 World server is up and running! Loading time: 1 minutes 52 seconds
2026-09-25 14:24:28 ERROR:CastCustomSpell: unknown spell id 0 by caster: Player Inder (Guid: 4) triggered by aura 14081 (eff 1)
2026-09-25 14:25:00 ERROR:[BOT PATH BUG] Dolane near IF AH - abnormal upward path detected!
2026-09-25 14:25:01 [PersistentRosterProfessionTraining] stage=trigger state=candidate
LOG

out=$("$smoke" --classify "$base") || fail 'known markers only must pass'
[[ $(count "$out" known-data) == 2 && $(count "$out" known-runtime) == 1 && $(count "$out" known-bot) == 1 ]] \
    || fail "unexpected class counts: $out"
pass 'startup data errors, known runtime and tracked bot markers pass'

cp "$base" "$tmp/unknown.log"
echo '2026-09-25 14:30:00 ERROR:Something nobody has classified yet 42' >> "$tmp/unknown.log"
if out=$("$smoke" --classify "$tmp/unknown.log"); then fail 'an unclassified runtime marker must fail'; fi
grep -q $'^example\tunknown\truntime:ERROR:Something nobody has classified yet N\t1$' <<<"$out" \
    || fail "unknown marker not reported normalized: $out"
pass 'unclassified runtime marker fails and is reported normalized'

# A data-load message is only "known" at startup; after world-up it is news.
cp "$base" "$tmp/late-data.log"
echo '2026-09-25 14:31:00 ERROR:Table creature_movement contain path for creature guid 9, but this creature guid does not exist. Skipping.' >> "$tmp/late-data.log"
if "$smoke" --classify "$tmp/late-data.log" >/dev/null; then fail 'startup-only pattern after world-up must fail'; fi
pass 'startup-only pattern after world-up fails'

cp "$base" "$tmp/fatal.log"
echo '2026-09-25 14:32:00 ASSERTION FAILED: map != nullptr' >> "$tmp/fatal.log"
if out=$("$smoke" --classify "$tmp/fatal.log"); then fail 'a fatal marker must fail'; fi
[[ $(count "$out" fatal) == 1 ]] || fail "fatal not counted: $out"
pass 'fatal marker fails'

# Without "World server is up" every line counts as startup, where any ERROR:
# line is data debt. The triage does not judge a hung or crashed start; the
# world.up check of the full smoke does, and it fails on exactly this log.
grep -v 'World server is up' "$base" > "$tmp/no-up.log"
out=$("$smoke" --classify "$tmp/no-up.log") || fail 'without world-up ERROR: lines are startup data debt'
[[ $(count "$out" known-data) == 4 && $(count "$out" known-runtime) == 0 ]] || fail "phase not startup: $out"
grep -q 'World server is up and running' "$smoke" || fail 'full smoke must check world-up'
pass 'without world-up all markers are startup; world.up is the guard'

# Every rule row: class, phase and pattern are well formed.
awk -F'\t' '/^#/ || /^[[:space:]]*$/ { next }
    NF < 3 || NF > 4 { print "bad field count: " $0; bad = 1 }
    $1 !~ /^(fatal|known-data|known-runtime|known-bot)$/ { print "bad class: " $1; bad = 1 }
    $2 !~ /^(startup|runtime|any)$/ { print "bad phase: " $2; bad = 1 }
    $1 == "known-bot" && $4 !~ /^#[0-9]+$/ { print "known-bot without tracking issue: " $3; bad = 1 }
    END { exit bad }' "$root/ops/live/error-triage.tsv" || fail 'triage rules malformed'
pass 'triage rules well formed; every known-bot row names its issue'
