#!/usr/bin/env bash
# Database bootstrap for the compose stack. Runs once per volume, in stages.
#
# This is the awkward part of the project and it is not worth hiding:
#
#  * sql/setup_databases.sh skips sql/base entirely -- 190 files, ~130 MB, the
#    entire world content -- and does not recurse into database_updates/{world,
#    character}. Using it alone gets you an empty world. This script does the
#    whole job instead; it does not call it.
#  * sql/base is a mixed snapshot, not "the first N migrations applied". Of the
#    migration files, some are already fully contained in it, some partially,
#    some not at all. There is therefore no honest set of rows for the
#    migrations table, and the updater replaying them collides on the first
#    duplicate key and refuses to start the server. So: apply with --force
#    (duplicate-key errors skipped, ALTERs land), record them, keep the updater
#    off. --force also swallows genuine errors. That is the price, and the
#    verification step at the end is why it is survivable.
#  * The recorded Hash is the literal string 'manual'. The updater keys on
#    Module + ":" + SHA1(file bytes), so 'manual' matches nothing on disk. It is
#    a tombstone meaning "a human decided this file is applied", and it only
#    works while Database.AutoUpdate.Enabled = 0.
#
# Idempotency is by stage marker under /state (a named volume). Each stage is
# skipped once done. Delete a marker to force that stage to re-run; delete the
# volume (make clean) to start over. This matters: create_databases.sql opens
# with DROP TABLE IF EXISTS on 415 tables.
set -euo pipefail

STATE=/state
SQL_DIR=${SQL_DIR:-/sql}
SQL_BASE_DIR=${SQL_BASE_DIR:-/sql-base}
PB_SQL_DIR=${PB_SQL_DIR:-/sql-playerbots}

DB_HOST=${DB_HOST:-db}
DB_PORT=${DB_PORT:-3306}

mysql_root() { mariadb -h "$DB_HOST" -P "$DB_PORT" -u root -p"$DB_ROOT_PASSWORD" "$@"; }
log() { printf '[db-init] %s\n' "$*" >&2; }

# Run stage $1 (marker name) with the rest as the command, once.
stage() {
    local name=$1; shift
    if [ -f "$STATE/$name" ]; then
        log "skip $name (already done $(cat "$STATE/$name"))"
        return 0
    fi
    log "running stage $name"
    "$@"
    date -Iseconds > "$STATE/$name"
    log "stage $name complete"
}

mkdir -p "$STATE"

# The healthcheck says the server is up; this says it will actually talk to us.
for _ in $(seq 1 60); do
    mysql_root -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 2
done
mysql_root -e 'SELECT 1' >/dev/null || { log "cannot reach $DB_HOST:$DB_PORT as root"; exit 1; }

# ---------------------------------------------------------------- 00 schemas
# create_databases.sql does far more than its name says: four databases plus 415
# table definitions, i.e. the complete schema for tw_char, tw_logon and tw_logs.
# Only world *content* is separate (sql/base).
stage_schemas() {
    [ -f "$SQL_DIR/create_databases.sql" ] || { log "missing $SQL_DIR/create_databases.sql"; exit 1; }
    mysql_root < "$SQL_DIR/create_databases.sql"
}

# ----------------------------------------------------------------- 10 grants
# The mariadb image only grants MARIADB_USER on MARIADB_DATABASE, and there are
# four databases here, so grants are made explicitly. The app user is not root:
# a SQL injection in a script should not be able to drop tw_logon.
stage_grants() {
    mysql_root <<SQL
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON tw_world.*  TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON tw_char.*   TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON tw_logon.*  TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON tw_logs.*   TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
}

# ------------------------------------------------------------- 20 world base
# The slow one: ~130 MB across 190 files. All of sql/base is tw_world_*, which
# is why there is no characters.sql to look for. Without this the server starts
# and the world is empty.
stage_base() {
    local n=0 total
    total=$(find "$SQL_BASE_DIR" -maxdepth 1 -name '*.sql' | wc -l)
    [ "$total" -gt 0 ] || { log "no .sql files in $SQL_BASE_DIR -- world content path is wrong"; exit 1; }
    while IFS= read -r f; do
        n=$((n + 1))
        log "base [$n/$total] $(basename "$f")"
        mysql_root tw_world < "$f"
    done < <(find "$SQL_BASE_DIR" -maxdepth 1 -name '*.sql' | sort)
}

# --------------------------------------------------------------- 30 updates
# setup_databases.sh only reads database_updates/*.sql; the world/ and
# character/ subdirectories (120 and 25 files) are also real migrations and are
# applied here. --force for the reason given at the top of this file.
apply_update_dir() {
    local dir=$1 db=$2
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        log "update ($db) $(basename "$f")"
        mariadb -h "$DB_HOST" -P "$DB_PORT" -u root -p"$DB_ROOT_PASSWORD" \
            --force "$db" < "$f" || true
    done < <(find "$dir" -maxdepth 1 -name '*.sql' | sort)
}

stage_updates() {
    # Top-level files are all *_world.sql; route by suffix anyway so a stray
    # character/auth file is not silently loaded into the wrong database.
    while IFS= read -r f; do
        case "$(basename "$f")" in
            *_character.sql) db=tw_char ;;
            *_auth.sql|*_logon.sql) db=tw_logon ;;
            *) db=tw_world ;;
        esac
        log "update ($db) $(basename "$f")"
        mariadb -h "$DB_HOST" -P "$DB_PORT" -u root -p"$DB_ROOT_PASSWORD" \
            --force "$db" < "$f" || true
    done < <(find "$SQL_DIR/database_updates" -maxdepth 1 -name '*.sql' | sort)

    apply_update_dir "$SQL_DIR/database_updates/world" tw_world
    apply_update_dir "$SQL_DIR/database_updates/character" tw_char

    # There are three competing conventions for "a character migration" in this
    # tree -- database_updates/character/, character_updates/ and wip_updates/ --
    # and only the first was applied here originally. That silently omitted
    # 20260830230336_ai_playerbot_persistent_active_roster.sql, so a freshly
    # bootstrapped stack had no ai_playerbot_roster_* tables at all and ADR-0024
    # invariant 1 had nowhere to store a roster. Collapsing the conventions is
    # REF-004; until then, apply all of them.
    apply_update_dir "$SQL_DIR/character_updates" tw_char
    apply_update_dir "$SQL_DIR/logon" tw_logon
}

# ----------------------------------------------------------- 40 playerbots
# Without these the server aborts on startup with "Table
# 'ai_playerbot_weightscales' doesn't exist" -- through an assertion, so the
# message scrolls past inside a stack trace. world/classic is the vanilla set;
# the tbc and wotlk siblings do not apply to this core. sql/other is
# maintenance tooling, not part of an install.
stage_playerbots() {
    if [ "${IMPORT_PLAYERBOTS:-ON}" != "ON" ]; then
        log "IMPORT_PLAYERBOTS is not ON; skipping playerbot schema"
        return 0
    fi
    [ -d "$PB_SQL_DIR" ] || { log "missing $PB_SQL_DIR"; exit 1; }
    cat "$PB_SQL_DIR"/world/*.sql "$PB_SQL_DIR"/world/classic/*.sql | mysql_root tw_world
    cat "$PB_SQL_DIR"/characters/*.sql | mysql_root tw_char
}

# ------------------------------------------------------ 50 record migrations
# Recorded so a later `Database.AutoUpdate.Enabled = 1` does not replay files
# that stage 30 already forced in. Hash is 'manual' -- see the header. There is
# no unique key on migrations.Name, so the insert is guarded by a SELECT rather
# than INSERT IGNORE, which would happily duplicate every row on a re-run.
record_migrations() {
    local dir=$1 db=$2 module=$3
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        local name; name=$(basename "$f" .sql)
        mysql_root "$db" <<SQL
INSERT INTO migrations (Name, Hash, AppliedAt)
SELECT '${name}', 'manual', NOW()
  FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM migrations WHERE Name = '${name}');
SQL
    done < <(find "$dir" -maxdepth 1 -name '*.sql' | sort)
    log "recorded $module migrations from $dir"
}

stage_record() {
    record_migrations "$SQL_DIR/database_updates" tw_world world
    record_migrations "$SQL_DIR/database_updates/world" tw_world world
    record_migrations "$SQL_DIR/database_updates/character" tw_char character
    record_migrations "$SQL_DIR/character_updates" tw_char character
    record_migrations "$SQL_DIR/logon" tw_logon auth
}

# -------------------------------------------------------------- 60 realmlist
# create_databases.sql creates realmlist and leaves it empty, so the realm list
# is empty until this runs. Two fields decide whether the client works at all:
# port must equal WorldServerPort (the column default 8085 disagrees with the
# config default 8090 -- login then succeeds and the client hangs before
# character select), and realmflags must be 0 (the default 2 means offline).
stage_realmlist() {
    mysql_root tw_logon <<SQL
INSERT INTO realmlist (name, address, port, icon, realmflags, timezone, allowedSecurityLevel)
SELECT '${REALM_NAME}', '${REALM_ADDRESS}', ${WORLD_PORT}, 0, 0, 1, 0
  FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM realmlist WHERE name = '${REALM_NAME}');
UPDATE realmlist SET address = '${REALM_ADDRESS}', port = ${WORLD_PORT}, realmflags = 0
 WHERE name = '${REALM_NAME}';
SQL
}

stage 00-schemas    stage_schemas
stage 10-grants     stage_grants
stage 20-world-base stage_base
stage 30-updates    stage_updates
stage 40-playerbots stage_playerbots
stage 50-record     stage_record
stage 60-realmlist  stage_realmlist

# Verification, because --force hides failures. This column is added by a
# migration and is absent from sql/base, so a 1 proves the schema changes landed.
probe=$(mysql_root -N -B -e "SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA='tw_world' AND TABLE_NAME='spell_template' AND COLUMN_NAME='script_name';")
if [ "$probe" != "1" ]; then
    log "FAILED: spell_template.script_name missing -- the migrations did not land."
    log "Inspect the log above for the first real (non duplicate-key) error."
    exit 1
fi

creatures=$(mysql_root -N -B -e "SELECT COUNT(*) FROM tw_world.creature;")
log "verified: schema migrated, tw_world.creature has ${creatures} rows"
date -Iseconds > "$STATE/.bootstrap-complete"
log "bootstrap complete"
