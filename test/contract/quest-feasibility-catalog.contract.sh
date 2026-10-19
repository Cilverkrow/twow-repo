#!/usr/bin/env bash
# Contract for the quest feasibility catalog (twow-repo#601 R08a, OB-00 decisions 2026-10-19; OB-30: a CI contract, not
# a local check). No database: ops/dbcheck/catalog/quest-feasibility.toml is the only hand-edited input, the rendered
# quest-feasibility.tsv / .keys must be current, and the two AiPlayerbot.QuestFeasibility.* lines of the test profile
# must equal the rendered .keys. The world check itself runs in the integration job (dbcheck catalog check).
# Then the guards are probed on throw-away copies: each mutation must make the lint fail.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DBCHECK="$ROOT/ops/dbcheck"
PROFILE="$ROOT/config/canonical/profiles/funserver-test/aiplayerbot.overlay.conf"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

lint() {   # lint <catalog dir> <profile>
    (cd "$DBCHECK" && python3 -m dbcheck catalog lint --catalog-dir "$1" --profile "$2")
}

echo "== the committed catalog"
lint "$DBCHECK/catalog" "$PROFILE"

fails=0
expect_fail() {   # expect_fail <name>: the lint of $WORK/cat with $WORK/profile must fail
    if lint "$WORK/cat" "$WORK/profile" > "$WORK/out" 2>&1; then
        echo "FAIL: mutation '$1' passed the lint"; cat "$WORK/out"; fails=$((fails + 1))
    else
        echo "ok: mutation '$1' caught"
    fi
}
fresh() {
    rm -rf "$WORK/cat"; cp -r "$DBCHECK/catalog" "$WORK/cat"; cp "$PROFILE" "$WORK/profile"
}

fresh
sed -i 's/^\(AiPlayerbot\.QuestFeasibility\.Blocklist = \)25,/\125,26,/' "$WORK/profile"
expect_fail "profile gains an id"

fresh
sed -i '/^AiPlayerbot\.QuestFeasibility\.BlocklistWhileNoCustomStarts =/d' "$WORK/profile"
expect_fail "profile loses a key line"

fresh
printf '\n[[quest]]\nentry = 99999\nlist = "blocklist"\nbasis = "override"\nclass = "impossible"\ncategory = "X"\ntitle = "X"\nreason = "x"\nevidence = "x"\n' >> "$WORK/cat/quest-feasibility.toml"
expect_fail "new id without an OB-00 approval (freeze)"

fresh
sed -i '0,/^reason = ".*"$/s//reason = "changed"/' "$WORK/cat/quest-feasibility.toml"
expect_fail "reason changed without regenerating the TSV"

fresh
sed -i '0,/^reason = ".*"$/s//reason = ""/' "$WORK/cat/quest-feasibility.toml"
expect_fail "empty reason"

fresh
sed -i '0,/^rule = "PVP_BG"$/s//rule = "NO_SUCH_RULE"/' "$WORK/cat/quest-feasibility.toml"
expect_fail "unknown rule"

[ "$fails" -eq 0 ] || { echo "quest feasibility catalog contract: $fails mutation(s) not caught"; exit 1; }
echo "quest feasibility catalog contract: OK"
