#!/usr/bin/env bash
# Applies the WS-10 V4 profession plan to the immutable active-roster prefix.
# This is an explicit maintenance gate.  It never runs during normal bootstrap.
set -euo pipefail

readonly SOURCE_MASTER_SHA256='4E313D575FBA261986F69562E42976C188D6759CDE5A9515398E8651A9E8F509'
readonly SOURCE_PREFIX_SHA256='51F0559A6914E0D3A4886CD0B21A669C15BCB54A48DC06E948E9BF55AF6AEC39'
readonly SOURCE_HEADER='ordinal,guid,account,name,race,class,gender,talent_path,role,profession_pair,selection_reason,source_candidate_hash'
readonly EXPECTED_COUNT=136
readonly EVENT_NAME='profession_pair'
readonly EVENT_DATA='v1'
readonly EVENT_VALID_IN=4294967295

die() { printf 'ROSTER_V4_GATE=FAIL: %s\n' "$*" >&2; exit 1; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print toupper($1)}';
    else shasum -a 256 "$1" | awk '{print toupper($1)}'; fi
}

validate_source() {
    local source="$1" out="$2" actual header
    [ -r "$source" ] || die "canonical source is unreadable: $source"
    actual=$(sha256 "$source")
    [ "$actual" = "$SOURCE_PREFIX_SHA256" ] || die "canonical prefix SHA-256 mismatch ($actual)"
    header=$(head -n 1 "$source" | tr -d '\r')
    [ "$header" = "$SOURCE_HEADER" ] || die 'canonical source header mismatch'
    awk -F, -v expected="$EXPECTED_COUNT" '
        NR == 1 { next }
        $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { exit 1 }
        $1 != NR - 1 || $2 == 0 { exit 1 }
        $10 !~ /^(Herbalism\/Alchemy|Skinning\/Leatherworking|Mining\/Blacksmithing|Mining\/Engineering|Mining\/Jewelcrafting|Tailoring\/Enchanting)$/ { exit 1 }
        seen[$2]++ != 0 { exit 1 }
        { print $1 "\t" $2 "\t" $10; count++ }
        END { exit !(count == expected) }
    ' "$source" > "$out" || die 'canonical source order, GUID, pair, or count validation failed'
    [ "$(wc -l < "$out" | tr -d ' ')" = "$EXPECTED_COUNT" ] || die 'canonical source row count mismatch'
}

main() {
    local source="${ROSTER_V4_SOURCE:-/roster/v4-136-profession-prefix.csv}"
    local schema="${TWOW_CHAR_SCHEMA:-tw_char}"
    local db_user="${DB_USER:-root}"
    local work target sql tuples changes
    work=$(mktemp -d)
    trap 'rm -rf "${work:-}"' EXIT INT TERM
    target="$work/target.tsv"
    validate_source "$source" "$target"
    if [ "${1:-}" = '--validate-source' ]; then
        printf 'ROSTER_V4_SOURCE_VALID=YES count=%s prefix_sha256=%s master_sha256=%s\n' "$EXPECTED_COUNT" "$SOURCE_PREFIX_SHA256" "$SOURCE_MASTER_SHA256"
        return 0
    fi

    [ "${ROSTER_V4_MAINTENANCE:-}" = YES ] || die 'set ROSTER_V4_MAINTENANCE=YES for this explicit maintenance operation'
    [[ "${ROSTER_V4_EXPECTED_ROSTER_VERSION:-}" =~ ^[1-9][0-9]*$ ]] || die 'ROSTER_V4_EXPECTED_ROSTER_VERSION must be an explicit positive integer'
    [[ "$schema" =~ ^[A-Za-z0-9_]+$ ]] || die 'TWOW_CHAR_SCHEMA is not a safe database identifier'
    : "${DB_HOST:?DB_HOST is required}"
    : "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required}"
    [[ "${DB_PORT:-3306}" =~ ^[0-9]+$ ]] || die 'DB_PORT must be numeric'

    tuples=$(awk -F'\t' '
        function value(p) {
            if (p == "Herbalism/Alchemy") return 1;
            if (p == "Skinning/Leatherworking") return 2;
            if (p == "Mining/Blacksmithing") return 3;
            if (p == "Mining/Engineering") return 4;
            if (p == "Mining/Jewelcrafting") return 5;
            if (p == "Tailoring/Enchanting") return 6;
            exit 1;
        }
        { printf "%s(%s,%s,%s)", (NR == 1 ? "" : ","), $1, $2, value($3) }
    ' "$target") || die 'failed to map a verified profession label to the current-core Pair enum'
    [ -n "$tuples" ] || die 'no verified roster targets were generated'

    sql="$work/gate.sql"
    cat > "$sql" <<SQL
SET SESSION sql_safe_updates = 0;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
START TRANSACTION;
CREATE TEMPORARY TABLE roster_v4_target (
  ordinal INT NOT NULL PRIMARY KEY,
  guid BIGINT UNSIGNED NOT NULL UNIQUE,
  value BIGINT UNSIGNED NOT NULL
) ENGINE=InnoDB;
INSERT INTO roster_v4_target (ordinal,guid,value) VALUES $tuples;
CREATE TEMPORARY TABLE roster_v4_assert (ok TINYINT NOT NULL CHECK (ok = 1)) ENGINE=InnoDB;
-- Schema/unique-key contract: this gate relies on exactly one owner/bot/event row.
INSERT INTO roster_v4_assert SELECT IF((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='cv_bots' AND table_name='ai_playerbot_random_bots' AND column_name IN ('owner','bot','time','validIn','event','value','data')) = 7, 1, 0);
INSERT INTO roster_v4_assert SELECT IF((SELECT COUNT(*) FROM (SELECT index_name FROM information_schema.statistics WHERE table_schema='cv_bots' AND table_name='ai_playerbot_random_bots' GROUP BY index_name HAVING MIN(non_unique)=0 AND COUNT(*)=3 AND GROUP_CONCAT(column_name ORDER BY seq_in_index SEPARATOR ',')='owner,bot,event') AS required_owner_bot_event_key) = 1, 1, 0);
-- The snapshot pointer and its complete, ordered prefix must match the operator-supplied version.
INSERT INTO roster_v4_assert SELECT IF((SELECT COUNT(*) FROM ai_playerbot_roster_current WHERE singleton_id=1 AND version_id=${ROSTER_V4_EXPECTED_ROSTER_VERSION}) = 1, 1, 0);
INSERT INTO roster_v4_assert SELECT IF((SELECT COUNT(*) FROM ai_playerbot_roster_member m JOIN ai_playerbot_roster_current c ON c.version_id=m.version_id JOIN roster_v4_target t ON t.ordinal=m.ordinal AND t.guid=m.character_guid WHERE c.singleton_id=1) = $EXPECTED_COUNT, 1, 0);
-- Every target must be a system random bot; a player or an arbitrary foreign GUID is rejected.
INSERT INTO roster_v4_assert SELECT IF((SELECT COUNT(*) FROM roster_v4_target t JOIN cv_bots.ai_playerbot_random_bots a ON a.owner=0 AND a.bot=t.guid AND a.event='add') = $EXPECTED_COUNT, 1, 0);
-- Existing target events must already be structurally valid.  Do not repair ambiguous rows.
INSERT INTO roster_v4_assert SELECT IF((SELECT COUNT(*) FROM cv_bots.ai_playerbot_random_bots p JOIN roster_v4_target t ON t.guid=p.bot WHERE p.event='$EVENT_NAME' AND (p.owner<>0 OR p.validIn IS NULL OR p.validIn<>$EVENT_VALID_IN OR p.data IS NULL OR p.data<>'$EVENT_DATA' OR p.value IS NULL OR p.value NOT BETWEEN 1 AND 6)) = 0, 1, 0);
INSERT INTO roster_v4_assert SELECT IF((SELECT COUNT(*) FROM cv_bots.ai_playerbot_random_bots p JOIN roster_v4_target t ON t.guid=p.bot WHERE p.event='$EVENT_NAME') <= $EXPECTED_COUNT, 1, 0);
-- Only the keyed profession_pair rows below can change; all other events and every non-target GUID are untouched.
INSERT INTO cv_bots.ai_playerbot_random_bots (owner,bot,time,validIn,event,value,data)
SELECT 0,t.guid,UNIX_TIMESTAMP(),$EVENT_VALID_IN,'$EVENT_NAME',t.value,'$EVENT_DATA'
FROM roster_v4_target t
LEFT JOIN cv_bots.ai_playerbot_random_bots p ON p.owner=0 AND p.bot=t.guid AND p.event='$EVENT_NAME'
WHERE p.bot IS NULL OR p.value<>t.value OR p.validIn<>$EVENT_VALID_IN OR p.data<>'$EVENT_DATA'
ON DUPLICATE KEY UPDATE time=VALUES(time),validIn=VALUES(validIn),value=VALUES(value),data=VALUES(data);
SET @roster_v4_changes := ROW_COUNT();
-- Postcondition is checked before commit, so any failed assertion rolls the transaction back.
INSERT INTO roster_v4_assert SELECT IF((SELECT COUNT(*) FROM roster_v4_target t JOIN cv_bots.ai_playerbot_random_bots p ON p.owner=0 AND p.bot=t.guid AND p.event='$EVENT_NAME' AND p.validIn=$EVENT_VALID_IN AND p.value=t.value AND p.data='$EVENT_DATA') = $EXPECTED_COUNT, 1, 0);
COMMIT;
SELECT @roster_v4_changes;
SQL
    changes=$(mariadb --protocol=tcp --host="$DB_HOST" --port="${DB_PORT:-3306}" --user="$db_user" "--password=$DB_ROOT_PASSWORD" --batch --skip-column-names "$schema" < "$sql" | tail -n 1) || die 'preflight or atomic profession_pair application failed; transaction was not committed'
    [[ "$changes" =~ ^[0-9]+$ ]] || die 'database did not return a change count'
    if [ "$changes" = 0 ]; then
        printf 'ROSTER_V4_GATE=NOOP count=%s roster_version=%s\n' "$EXPECTED_COUNT" "$ROSTER_V4_EXPECTED_ROSTER_VERSION"
    else
        printf 'ROSTER_V4_GATE=APPLIED count=%s row_changes=%s roster_version=%s\n' "$EXPECTED_COUNT" "$changes" "$ROSTER_V4_EXPECTED_ROSTER_VERSION"
    fi
}

main "$@"
