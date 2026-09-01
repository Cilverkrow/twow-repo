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
#    some not at all. The migration files themselves absorb that: they are
#    written with IF NOT EXISTS / IF EXISTS / INSERT IGNORE, so replaying one
#    over a base that already contains it is a no-op rather than a duplicate-key
#    error. Replaying every one of them for real against an empty mariadb:11.8,
#    one file at a time and with no --force, produces no duplicate-key error at
#    all -- so the argument that --force is needed for them does not survive
#    being tested. What --force was hiding was ordering: see stage 30.
#  * A migration is recorded ONLY after the client that applied it exited 0, and
#    the recorded Hash is the uppercase SHA-1 of the file's bytes -- the same
#    digest the AutoUpdater computes (src/shared/Database/AutoUpdater.cpp
#    CalculateFileHash, printed with %02X by ByteArrayToHexStr). It used to be
#    the literal string 'manual', which matched nothing on disk and therefore
#    told the updater nothing; worse, it was written whether or not the file had
#    applied. That is OPS-020, and it is where the 146 unverifiable rows of
#    OPS-012 came from.
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
# character/ subdirectories are also real migrations and are applied here.
#
# Applying and recording are ONE operation now, and that is the whole point of
# OPS-020. They used to be two stages: 30 applied every file with --force and
# `|| true`, and 50 walked the same directories afterwards inserting a row per
# filename regardless of what had happened. A migration that could not run --
# 20260708055500_ai_playerbot_random_bots_index.sql could not, because its table
# was created in stage 40, one stage later -- was therefore recorded as applied
# and never retried. The database said the index existed; it did not.
#
# So: no --force (it continues past errors inside a file), no `|| true` (it
# throws the exit code away), and a row is written only on the far side of a
# client that exited 0. `set -e` at the top of this file is finally allowed to
# mean what it says.

# The digest the AutoUpdater looks for. It SHA-1s the file's raw bytes and
# renders them with %02X, so the hex must be UPPER case or the ledger row will
# not match the file it claims to describe and the updater will replay it
# (src/shared/Database/AutoUpdater.cpp: CalculateFileHash, GetMigrationKey --
# the key is Module + ":" + hash, and Module is empty for these core folders,
# which is why only the hash is written here).
migration_hash() { sha1sum "$1" | cut -d' ' -f1 | tr 'a-f' 'A-F'; }

# Apply one file, then record it. The failure path exits rather than returning,
# because the honest thing to do with a migration that will not apply is to stop
# the bootstrap with the filename on screen -- not to carry on and leave a
# database whose ledger disagrees with its schema.
#
# The insert is guarded by a SELECT rather than INSERT IGNORE because
# migrations.Name carries no unique key (sql/create_databases.sql: the PRIMARY
# KEY is the autoincrement Id), so IGNORE would cheerfully duplicate every row.
apply_migration() {
    local db=$1 f=$2 name hash
    name=$(basename "$f" .sql)
    log "update ($db) $name"
    mysql_root "$db" < "$f" || {
        log "FAILED: $name did not apply to $db -- the client error is above."
        log "It is NOT recorded, so fixing the file (or its ordering) and re-running"
        log "will apply it. Delete $STATE/30-updates to force this stage to re-run."
        exit 1
    }
    hash=$(migration_hash "$f")
    mysql_root "$db" <<SQL
INSERT INTO migrations (Name, Hash, AppliedAt)
SELECT '${name}', '${hash}', NOW()
  FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM migrations WHERE Name = '${name}');
SQL
}

apply_update_dir() {
    local dir=$1 db=$2 n=0
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        apply_migration "$db" "$f"
        n=$((n + 1))
    done < <(find "$dir" -maxdepth 1 -name '*.sql' | LC_ALL=C sort)
    log "applied and recorded $n migrations from $dir into $db"
}

# tw_world's migrations are split across TWO directories -- sql/database_updates/
# and sql/database_updates/world/ -- and they are one chronological stream, not
# two. Applying one directory and then the other is what broke four of them.
# world/20260721013813_world.sql is the migration that ADDS
# spell_template.script_name; 20260731120000, 20260731180000, 20260731190000 and
# 20260805120000 at the top level all write that column. Directory order put the
# writers first, so every fresh bootstrap failed all four on the missing column
# and the old stage 50 recorded them as applied regardless.
#
# Both directories use the same YYYYMMDDHHMMSS_ prefix and no basename occurs in
# both, so sorting the union by basename puts them back in the order they were
# written. The pairs are emitted as "basename<TAB>path" so the sort key is the
# filename and not the directory it happens to sit in.
#
# Ordering by directory also quietly reverted work. Ten top-level migrations
# write tables that a world/ migration later drops and recreates -- npc_trainer,
# creature_template, npc_vendor, game_graveyard_zone -- so their rows were
# inserted and then deleted again a few files later, with a ledger row saying
# they had been applied. In timestamp order no top-level file is followed by a
# world/ file that drops a table it wrote, so that class of loss disappears too.
#
# It does surface one real conflict that no ordering can fix, because both files
# claim the same row: 20260617120000_world.sql (ours, the Blackstone trainer
# lists) and world/20260718150344_world.sql (the 2026-08-17 upstream import) both
# INSERT npc_trainer (80106, 1780), and the second one now hits
# ERROR 1062 Duplicate entry '80106-1780' for key 'entry_spell' instead of
# landing on a table the first one's rows had just been wiped from. That is a
# content decision about which trainer list is correct, in files this change does
# not own; it is reported with OPS-020 rather than papered over here.
world_migration_stream() {
    {
        find "$SQL_DIR/database_updates" -maxdepth 1 -name '*.sql'
        find "$SQL_DIR/database_updates/world" -maxdepth 1 -name '*.sql'
    } | while IFS= read -r p; do
        printf '%s\t%s\n' "$(basename "$p")" "$p"
    done | LC_ALL=C sort | cut -f2-
}

stage_updates() {
    # Everything in that stream is *_world.sql today; route by suffix anyway so
    # a stray character/auth file is not silently loaded into the wrong database.
    while IFS= read -r f; do
        case "$(basename "$f")" in
            *_character.sql) db=tw_char ;;
            *_auth.sql|*_logon.sql) db=tw_logon ;;
            *) db=tw_world ;;
        esac
        apply_migration "$db" "$f"
    done < <(world_migration_stream)

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
#
# These files are module schema, not migrations: they are the CREATE statements
# for the module's own tables, no `migrations` ledger tracks them, and
# ai_playerbot_random_bots.sql leads with DROP TABLE IF EXISTS. That last point
# is why the index on ai_playerbot_random_bots belongs here rather than in
# sql/character_updates. Applied in stage 30 it would be dropped again one stage
# later by that DROP+CREATE, so swapping the order of stages 30 and 40 does not
# fix it either -- it only moves the breakage. A file that adds an index to a
# module's table has to travel with the table.
#
# Applied one file at a time rather than `cat *.sql | mariadb`, for two reasons.
# Five of these files end without a trailing newline, so concatenation splices
# the last line of one onto the first line of the next -- harmless today only
# because those last lines happen to end in ';'. And order is now load-bearing:
# ai_playerbot_random_bots_index.sql must follow ai_playerbot_random_bots.sql.
# LC_ALL=C makes that a fact rather than a locale accident ('.' is 0x2E and '_'
# is 0x5F, so the CREATE sorts first); a locale that ignores punctuation when
# comparing would not guarantee it.
apply_module_sql() {
    local db=$1; shift
    local dir f
    for dir in "$@"; do
        [ -d "$dir" ] || { log "missing $dir"; exit 1; }
        while IFS= read -r f; do
            log "module sql ($db) ${f#"$PB_SQL_DIR"/}"
            mysql_root "$db" < "$f" || {
                log "FAILED: module schema $f did not apply to $db."
                exit 1
            }
        done < <(find "$dir" -maxdepth 1 -name '*.sql' | LC_ALL=C sort)
    done
}

stage_playerbots() {
    if [ "${IMPORT_PLAYERBOTS:-ON}" != "ON" ]; then
        log "IMPORT_PLAYERBOTS is not ON; skipping playerbot schema"
        return 0
    fi
    [ -d "$PB_SQL_DIR" ] || { log "missing $PB_SQL_DIR"; exit 1; }
    apply_module_sql tw_world "$PB_SQL_DIR/world" "$PB_SQL_DIR/world/classic"
    apply_module_sql tw_char  "$PB_SQL_DIR/characters"
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
stage 60-realmlist  stage_realmlist

# Verification. Every stage above now fails loudly, so this is no longer the only
# thing between a broken bootstrap and a server that starts anyway. It is kept as
# an end-to-end assertion that the migrations reached the schema and not merely
# the ledger: this column is added by a migration and is absent from sql/base, so
# a 1 proves the schema changes landed.
probe=$(mysql_root -N -B -e "SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA='tw_world' AND TABLE_NAME='spell_template' AND COLUMN_NAME='script_name';")
if [ "$probe" != "1" ]; then
    log "FAILED: spell_template.script_name missing -- the migrations did not land."
    log "Inspect the log above for the first error; nothing is swallowed any more."
    exit 1
fi

creatures=$(mysql_root -N -B -e "SELECT COUNT(*) FROM tw_world.creature;")
log "verified: schema migrated, tw_world.creature has ${creatures} rows"
date -Iseconds > "$STATE/.bootstrap-complete"
log "bootstrap complete"
