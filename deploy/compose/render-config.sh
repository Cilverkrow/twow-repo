#!/usr/bin/env bash
# Render deploy/compose/config/{mangosd,realmd,aiplayerbot}.conf from the
# sanitized examples in config/examples plus deploy/compose/.env.
#
# The server has no environment-variable substitution: it reads a flat file, and
# credentials live in it. So credentials stay in .env (gitignored) and are
# stamped into a generated, also-gitignored config directory. Nothing rendered
# here is ever committed.
#
# Existing files are left alone unless FORCE=1, because operators edit them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
EXAMPLES="$ROOT/config/examples"
OUT="$HERE/config"

: "${DB_USER:?DB_USER not set -- source deploy/compose/.env first}"
: "${DB_PASSWORD:?DB_PASSWORD not set -- source deploy/compose/.env first}"
WORLD_PORT=${WORLD_PORT:-8090}
AIPLAYERBOT_MIN_BOTS=${AIPLAYERBOT_MIN_BOTS:-10}
AIPLAYERBOT_MAX_BOTS=${AIPLAYERBOT_MAX_BOTS:-10}

# Inside the compose network. Not 127.0.0.1: that would be the game server itself.
CONN_HOST=db
CONN_PORT=3306

mkdir -p "$OUT"

conn() { printf '%s;%s;%s;%s;%s' "$CONN_HOST" "$CONN_PORT" "$DB_USER" "$DB_PASSWORD" "$1"; }

keep() {  # keep <file> -> true if it exists and FORCE is not set
    if [ -f "$1" ] && [ "${FORCE:-0}" != "1" ]; then
        echo "keeping existing $(basename "$1") (FORCE=1 to overwrite)" >&2
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------- mangosd
if ! keep "$OUT/mangosd.conf"; then
    sed \
        -e "s|^LoginDatabase.Info.*|LoginDatabase.Info = \"$(conn tw_logon)\"|" \
        -e "s|^WorldDatabase.Info.*|WorldDatabase.Info = \"$(conn tw_world)\"|" \
        -e "s|^CharacterDatabase.Info.*|CharacterDatabase.Info = \"$(conn tw_char)\"|" \
        -e "s|^LogsDatabase.Info.*|LogsDatabase.Info = \"$(conn tw_logs)\"|" \
        -e 's|^DataDir.*|DataDir = "/opt/turtle/data"|' \
        -e 's|^LogsDir.*|LogsDir = "/var/log/turtle"|' \
        -e 's|^HonorDir.*|HonorDir = "/var/log/turtle"|' \
        -e 's|^PDumpDir.*|PDumpDir = "/var/log/turtle"|' \
        -e 's|^AiPlayerbot.ConfigFile.*|AiPlayerbot.ConfigFile = "/opt/turtle/etc/aiplayerbot.conf"|' \
        -e 's|^Database.AutoUpdate.Path.*|Database.AutoUpdate.Path = "/opt/turtle/sql/database_updates/"|' \
        -e 's|^Database.AutoUpdate.Enabled.*|Database.AutoUpdate.Enabled = 0|' \
        -e 's|^WorldServerPort.*|WorldServerPort = '"$WORLD_PORT"'|' \
        -e 's|^LogSQL.*|LogSQL = 0|' \
        -e 's|^PidFile.*|PidFile = "/tmp/twlive.pid"|' \
        "$EXAMPLES/mangosd.local.example.conf" > "$OUT/mangosd.conf"

    # Appended rather than edited in place: these are the settings whose defaults
    # are actively wrong for a containerised first start, and it is worth being
    # able to see them in one block. Later keys win in this parser.
    cat >> "$OUT/mangosd.conf" <<'EOF'

########################################################################
# Rendered by deploy/compose/render-config.sh -- edits here survive, but
# `FORCE=1 make config` overwrites the whole file.
########################################################################

# The auto-updater is OFF and must stay off on a database bootstrapped by
# db-init.sh. It keys migrations on Module + ":" + SHA1(file bytes), while the
# 146 world rows db-init writes carry the literal Hash 'manual', which matches
# no file on disk. Switch this on and it replays every migration, hits the first
# duplicate key, and the server refuses to start. Turning it on is only safe on
# a database that was built through the updater from empty.
Database.AutoUpdate.Enabled = 0

# Writes every SQL statement to disk. The first start with playerbots computes
# the gear cache for every class, spec and level -- tens of thousands of inserts.
LogSQL = 0
EOF
    echo "wrote $OUT/mangosd.conf" >&2
fi

# -------------------------------------------------------------------- realmd
if ! keep "$OUT/realmd.conf"; then
    sed \
        -e "s|^LoginDatabaseInfo.*|LoginDatabaseInfo = \"$(conn tw_logon)\"|" \
        -e 's|^LogsDir.*|LogsDir = "/var/log/turtle/"|' \
        -e 's|^PatchesDir.*|PatchesDir = "/opt/turtle/patches"|' \
        -e 's|^PidFile.*|PidFile = "/tmp/twrealmd.pid"|' \
        "$EXAMPLES/realmd.local.example.conf" > "$OUT/realmd.conf"
    echo "wrote $OUT/realmd.conf" >&2
fi

# ---------------------------------------------------------------- aiplayerbot
# The bot switch is not a mangosd.conf key, which is easy to trip over since
# every other one is.
if ! keep "$OUT/aiplayerbot.conf"; then
    sed \
        -e 's|^AiPlayerbot.Enabled.*|AiPlayerbot.Enabled = 1|' \
        -e 's|^AiPlayerbot.MinRandomBots.*|AiPlayerbot.MinRandomBots = '"$AIPLAYERBOT_MIN_BOTS"'|' \
        -e 's|^AiPlayerbot.MaxRandomBots.*|AiPlayerbot.MaxRandomBots = '"$AIPLAYERBOT_MAX_BOTS"'|' \
        "$EXAMPLES/aiplayerbot.local.example.conf" > "$OUT/aiplayerbot.conf"
    cat >> "$OUT/aiplayerbot.conf" <<EOF

# Rendered by deploy/compose/render-config.sh.
# The shipped template asks for a thousand bots, all created and geared before
# the world finishes coming up: a long first start for no benefit. Raise once
# the server is known good.
AiPlayerbot.MinRandomBots = ${AIPLAYERBOT_MIN_BOTS}
AiPlayerbot.MaxRandomBots = ${AIPLAYERBOT_MAX_BOTS}
EOF
    echo "wrote $OUT/aiplayerbot.conf" >&2
fi

chmod 600 "$OUT"/*.conf
