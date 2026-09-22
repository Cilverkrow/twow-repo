#!/usr/bin/env bash
# Disposable MariaDB matrix for the explicit V4 profession maintenance gate.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly source_csv="$repo/deploy/roster/v4-136-profession-prefix.csv"
readonly gate='/repo/deploy/compose/roster-v4-profession-backfill.sh'
readonly container="twow-roster-v4-contract-${GITHUB_RUN_ID:-local}-$$"
readonly db_auth="contract-${container##*-}"
tmp=$(mktemp -d)
trap 'docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT INT TERM

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
command -v docker >/dev/null 2>&1 || fail 'docker is required'
test -r "$source_csv" || fail 'canonical source is missing'

docker run -d --rm --name "$container" --label twow.contract=roster-v4 \
  -e "MARIADB_ROOT_PASSWORD=$db_auth" -v "$repo:/repo:ro" mariadb:11.8 >/dev/null
for _ in $(seq 1 60); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || true)
  [ "$health" = healthy ] && break
  [ "$health" = unhealthy ] && fail 'disposable MariaDB became unhealthy'
  sleep 1
done
[ "${health:-}" = healthy ] || fail 'disposable MariaDB did not become healthy'

sql() { docker exec -e "MYSQL_PWD=$db_auth" "$container" mariadb -u root -N -B "$@"; }
sql_stdin() { docker exec -e "MYSQL_PWD=$db_auth" -i "$container" mariadb -u root; }
gate_run() {
  local roster_version="${ROSTER_V4_TEST_VERSION:-42}"
  docker exec -e DB_HOST=127.0.0.1 -e DB_PORT=3306 -e "DB_ROOT_PASSWORD=$db_auth" \
    -e ROSTER_V4_MAINTENANCE=YES -e "ROSTER_V4_EXPECTED_ROSTER_VERSION=$roster_version" \
    -e ROSTER_V4_SOURCE=/repo/deploy/roster/v4-136-profession-prefix.csv \
    "$container" bash "$gate"
}
wrong_roster_version() { ROSTER_V4_TEST_VERSION=43 gate_run; }

fixture() {
  {
    cat <<'SQL'
DROP DATABASE IF EXISTS tw_char;
DROP DATABASE IF EXISTS cv_bots;
CREATE DATABASE tw_char;
CREATE DATABASE cv_bots;
CREATE TABLE tw_char.ai_playerbot_roster_current (singleton_id TINYINT NOT NULL PRIMARY KEY, version_id BIGINT NOT NULL);
CREATE TABLE tw_char.ai_playerbot_roster_member (version_id BIGINT NOT NULL, ordinal INT NOT NULL, character_guid BIGINT UNSIGNED NOT NULL, PRIMARY KEY(version_id, ordinal));
CREATE TABLE tw_char.character_talent (guid BIGINT UNSIGNED NOT NULL, spell BIGINT NOT NULL);
CREATE TABLE tw_char.character_queststatus (guid BIGINT UNSIGNED NOT NULL, quest BIGINT NOT NULL);
CREATE TABLE tw_char.character_inventory (guid BIGINT UNSIGNED NOT NULL, item BIGINT NOT NULL);
CREATE TABLE tw_char.character_skills (guid BIGINT UNSIGNED NOT NULL, skill BIGINT NOT NULL);
CREATE TABLE cv_bots.ai_playerbot_random_bots (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  owner BIGINT UNSIGNED NOT NULL, bot BIGINT UNSIGNED NOT NULL, time BIGINT NOT NULL,
  validIn BIGINT NULL, event VARCHAR(45) NOT NULL, value BIGINT NULL, data VARCHAR(255) NULL,
  UNIQUE KEY uq_owner_bot_event (owner, bot, event)
);
INSERT INTO tw_char.ai_playerbot_roster_current VALUES (1,42);
INSERT INTO tw_char.character_talent VALUES (999,11);
INSERT INTO tw_char.character_queststatus VALUES (999,22);
INSERT INTO tw_char.character_inventory VALUES (999,33);
INSERT INTO tw_char.character_skills VALUES (999,44);
INSERT INTO cv_bots.ai_playerbot_random_bots (owner,bot,time,validIn,event,value,data) VALUES
  (0,999,1,4294967295,'profession_pair',6,'v1'),
  (0,999,1,4294967295,'add',NULL,NULL),
  (0,50,1,4294967295,'strategy',17,'sentinel');
SQL
    awk -F, 'NR > 1 {
      printf "INSERT INTO tw_char.ai_playerbot_roster_member VALUES (42,%s,%s);\n", $1, $2;
      printf "INSERT INTO cv_bots.ai_playerbot_random_bots (owner,bot,time,validIn,event,value,data) VALUES (0,%s,1,4294967295,\047add\047,NULL,NULL);\n", $2;
    }' "$source_csv"
  } | sql_stdin
}

expected_target() {
  awk -F, '
    function value(p) {
      if (p=="Herbalism/Alchemy") return 1; if (p=="Skinning/Leatherworking") return 2;
      if (p=="Mining/Blacksmithing") return 3; if (p=="Mining/Engineering") return 4;
      if (p=="Mining/Jewelcrafting") return 5; if (p=="Tailoring/Enchanting") return 6; exit 1
    }
    NR > 1 { printf "0|%s|4294967295|profession_pair|%s|v1\n", $2, value($10) }
  ' "$source_csv" | sort -t'|' -k2,2n
}
actual_target() {
  sql "SELECT CONCAT(owner,'|',bot,'|',validIn,'|',event,'|',value,'|',data) FROM cv_bots.ai_playerbot_random_bots WHERE owner=0 AND event='profession_pair' AND bot<>999 ORDER BY bot;" | sort -t'|' -k2,2n
}
snapshot() {
  sql "SELECT CONCAT('E|',owner,'|',bot,'|',time,'|',COALESCE(validIn,'NULL'),'|',event,'|',COALESCE(value,'NULL'),'|',COALESCE(data,'NULL')) FROM cv_bots.ai_playerbot_random_bots WHERE bot=999 OR event<>'profession_pair' ORDER BY id; SELECT CONCAT('T|',guid,'|',spell) FROM tw_char.character_talent; SELECT CONCAT('Q|',guid,'|',quest) FROM tw_char.character_queststatus; SELECT CONCAT('I|',guid,'|',item) FROM tw_char.character_inventory; SELECT CONCAT('S|',guid,'|',skill) FROM tw_char.character_skills;"
}
expect_fail_atomic() {
  local label="$1"; shift
  local before after
  before=$(snapshot; actual_target)
  if "$@" >"$tmp/$label.out" 2>&1; then fail "$label unexpectedly succeeded"; fi
  after=$(snapshot; actual_target)
  [ "$before" = "$after" ] || fail "$label changed persistent state"
  pass "$label fails atomically"
}

fixture
gate_run | grep -q 'ROSTER_V4_GATE=APPLIED' || fail 'canonical apply did not report APPLIED'
diff -u <(expected_target) <(actual_target) || fail 'canonical apply target values differ'
after_apply=$(snapshot; actual_target)
gate_run | grep -q 'ROSTER_V4_GATE=NOOP' || fail 'second canonical apply did not report NOOP'
[ "$after_apply" = "$(snapshot; actual_target)" ] || fail 'second run changed target or sentinels'
pass 'canonical APPLY and repeat NOOP preserve state'

fixture; expect_fail_atomic wrong-roster-version wrong_roster_version
fixture; sql "UPDATE tw_char.ai_playerbot_roster_member SET character_guid=100001 WHERE version_id=42 AND ordinal=1;"
expect_fail_atomic roster-order-guid-deviation gate_run
fixture; sql "DELETE FROM cv_bots.ai_playerbot_random_bots WHERE owner=0 AND bot=50 AND event='add';"
expect_fail_atomic missing-add-event gate_run
fixture; sql "UPDATE cv_bots.ai_playerbot_random_bots SET owner=77 WHERE owner=0 AND bot=50 AND event='add';"
expect_fail_atomic foreign-bot-or-player gate_run
fixture; sql "INSERT INTO cv_bots.ai_playerbot_random_bots (owner,bot,time,validIn,event,value,data) VALUES (0,50,1,4294967295,'profession_pair',99,'v1');"
expect_fail_atomic invalid-existing-profession-pair gate_run
fixture; sql "ALTER TABLE cv_bots.ai_playerbot_random_bots DROP INDEX uq_owner_bot_event;"
expect_fail_atomic missing-owner-bot-event-unique-key gate_run

fixture
awk -F, '
  function value(p) {
    if (p=="Herbalism/Alchemy") return 1; if (p=="Skinning/Leatherworking") return 2;
    if (p=="Mining/Blacksmithing") return 3; if (p=="Mining/Engineering") return 4;
    if (p=="Mining/Jewelcrafting") return 5; if (p=="Tailoring/Enchanting") return 6; exit 1
  }
  NR > 1 && NR <= 31 { printf "INSERT INTO cv_bots.ai_playerbot_random_bots (owner,bot,time,validIn,event,value,data) VALUES (0,%s,1,4294967295,\047profession_pair\047,%s,\047v1\047);\n", $2, value($10) }
' "$source_csv" | sql_stdin
gate_run | grep -q 'ROSTER_V4_GATE=APPLIED' || fail 'partial target completion did not apply'
diff -u <(expected_target) <(actual_target) || fail 'partial target was not completed exactly'
pass 'partial target is completed exactly'

fixture
before=$(snapshot)
gate_run | grep -q 'ROSTER_V4_GATE=APPLIED' || fail 'non-target protection apply failed'
[ "$before" = "$(snapshot)" ] || fail 'non-target events or character state changed'
pass 'non-target GUIDs, other events, talents, quests, inventory and skills are unchanged'
printf 'ROSTER_V4_MARIADB_CONTRACT_MATRIX=PASS\n'
