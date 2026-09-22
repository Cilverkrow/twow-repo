#!/usr/bin/env bash
# Pure contract checks: no database, Docker daemon, or runtime is contacted.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
gate="$root/deploy/compose/roster-v4-profession-backfill.sh"
source_csv="$root/deploy/roster/v4-136-profession-prefix.csv"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
expect_fail() { if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }

ROSTER_V4_SOURCE="$source_csv" "$gate" --validate-source >/dev/null || fail 'canonical source must validate'
pass 'canonical source'
cp "$source_csv" "$tmp/bad-hash.csv"; sed -i '2s/,50,/,51,/' "$tmp/bad-hash.csv"
expect_fail env ROSTER_V4_SOURCE="$tmp/bad-hash.csv" "$gate" --validate-source; pass 'source hash deviation fails closed'
head -n 136 "$source_csv" > "$tmp/bad-count.csv"
expect_fail env ROSTER_V4_SOURCE="$tmp/bad-count.csv" "$gate" --validate-source; pass 'count deviation fails closed'
cp "$source_csv" "$tmp/bad-order.csv"; sed -i '2s/^1,/2,/' "$tmp/bad-order.csv"
expect_fail env ROSTER_V4_SOURCE="$tmp/bad-order.csv" "$gate" --validate-source; pass 'order deviation fails closed'
cp "$source_csv" "$tmp/duplicate-guid.csv"; sed -i '3s/^[0-9]*,[0-9]*/2,50/' "$tmp/duplicate-guid.csv"
expect_fail env ROSTER_V4_SOURCE="$tmp/duplicate-guid.csv" "$gate" --validate-source; pass 'duplicate GUID fails closed'
cp "$source_csv" "$tmp/invalid-pair.csv"; sed -i '2s/Herbalism\/Alchemy/Bad\/Pair/' "$tmp/invalid-pair.csv"
expect_fail env ROSTER_V4_SOURCE="$tmp/invalid-pair.csv" "$gate" --validate-source; pass 'invalid pair fails closed'
grep -q 'START TRANSACTION;' "$gate" && grep -q 'COMMIT;' "$gate" || fail 'atomic transaction contract missing'
grep -q "p.event='\$EVENT_NAME'" "$gate" || fail 'event scope missing'
grep -q 'JOIN characters c ON c.guid=t.guid JOIN tw_logon.account a' "$gate" &&
  grep -q 'RNDBOT\[0-9\]' "$gate" || fail 'persistent system-account target rejection missing'
grep -q 'ai_playerbot_roster_member m JOIN ai_playerbot_roster_current' "$gate" || fail 'active-roster prefix identity check missing'
grep -q 'p.validIn IS NULL' "$gate" && grep -q 'p.value IS NULL' "$gate" || fail 'ambiguous existing event rejection missing'
grep -q 'LEFT JOIN cv_bots.ai_playerbot_random_bots p ON p.owner=0 AND p.bot=t.guid' "$gate" || fail 'keyed target update missing'
pass 'transaction, target, and other-event protection contracts'
printf 'ROSTER_V4_CONTRACT_TEST=PASS\n'
