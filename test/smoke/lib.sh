# shellcheck shell=sh
# Shared helpers for the smoke suite. Sourced, never executed.
#
# Everything here exists so a check script can be read in one screen and say
# exactly one thing. The three conventions the whole suite depends on:
#
#   exit 0  PASS   the thing this script proves is true
#   exit 1  FAIL   it is false, and the run is red
#   exit 77 SKIP   it could not be proven here, and the reason is printed
#
# 77 is the autotools skip code. It matters because CI has no game client:
# without maps/vmaps/mmaps the world server cannot start, so any check that
# needs a running world MUST say so out loud rather than pass quietly. A silent
# pass on an untested invariant is the failure mode this suite exists to avoid.

SMOKE_SKIP=77

# Everything is overridable so the suite runs against a local compose stack, a
# stack with different ports, or a remote host - not only against CI.
: "${TWOW_COMPOSE_FILE:=deploy/compose/docker-compose.yml}"
# The compose file declares required variables (DB_ROOT_PASSWORD, DB_PASSWORD)
# with `:?`, so it will not even parse without the env file. Passed explicitly
# rather than relying on the working directory, because these scripts are run
# from the repository root.
: "${TWOW_ENV_FILE:=deploy/compose/.env}"

# Load it, rather than only handing it to `docker compose --env-file`.
#
# TWOW_DB_PASSWORD below defaults from $DB_ROOT_PASSWORD in the ENVIRONMENT,
# and nothing populated that environment: the file was passed to compose and
# never sourced. So following the README literally -- `sh test/smoke/run-all.sh`
# -- left the password empty and every database check failed with "database
# query failed", while the same checks passed the moment DB_ROOT_PASSWORD was
# exported by hand. A harness whose documented invocation cannot work is worse
# than no harness.
#
# `set -a` so the values are exported for `docker compose exec -e` and for the
# child scripts. Existing environment wins: the file is loaded only to fill
# gaps, so an explicit override on the command line still takes precedence.
if [ -f "$TWOW_ENV_FILE" ]; then
    __twow_saved_env=$(export -p)
    set -a
    # shellcheck disable=SC1090  # runtime path, by design
    . "$TWOW_ENV_FILE"
    set +a
    eval "$__twow_saved_env"
    unset __twow_saved_env
fi
: "${TWOW_DB_SERVICE:=db}"
: "${TWOW_WORLD_SERVICE:=mangosd}"
: "${TWOW_REALM_SERVICE:=realmd}"
: "${TWOW_HOST:=127.0.0.1}"
: "${TWOW_REALMD_PORT:=3724}"
: "${TWOW_WORLD_PORT:=8090}"
: "${TWOW_CHAR_SCHEMA:=tw_char}"
: "${TWOW_WORLD_SCHEMA:=tw_world}"
: "${TWOW_LOGON_SCHEMA:=tw_logon}"
: "${TWOW_LOGS_SCHEMA:=tw_logs}"
: "${TWOW_DB_USER:=root}"
: "${TWOW_DB_PASSWORD:=${DB_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}}"
# The FIFO the entrypoint holds open read-write; it is the server's console.
: "${TWOW_FIFO:=/opt/turtle/run/mangosd.in}"
# Where the compose file mounts client data inside the world container.
# SYSCONFDIR is compiled into the binary, so this path is not free to move.
: "${TWOW_DATA_DIR:=/opt/turtle/data}"
# auto | 0 | 1 - whether client data is mounted into the world container.
: "${TWOW_CLIENT_DATA:=auto}"
: "${TWOW_TIMEOUT:=120}"

smoke_name="$(basename "$0" .sh)"

pass() { printf 'PASS %-20s %s\n' "$smoke_name" "$*"; exit 0; }
fail() { printf 'FAIL %-20s %s\n' "$smoke_name" "$*"; exit 1; }
skip() { printf 'SKIP %-20s %s\n' "$smoke_name" "$*"; exit "$SMOKE_SKIP"; }
info() { printf '     %-20s %s\n' "$smoke_name" "$*"; }

# docker compose, pinned to the project's file. Kept in one place because every
# script needs it and because -f is the only thing that makes the suite work
# from a directory other than deploy/compose.
dc() {
    if [ -f "$TWOW_ENV_FILE" ]; then
        docker compose -f "$TWOW_COMPOSE_FILE" --env-file "$TWOW_ENV_FILE" "$@"
    else
        docker compose -f "$TWOW_COMPOSE_FILE" "$@"
    fi
}

require_stack() {
    command -v docker >/dev/null 2>&1 || skip "docker is not installed"
    [ -f "$TWOW_COMPOSE_FILE" ] || skip "no compose file at $TWOW_COMPOSE_FILE (set TWOW_COMPOSE_FILE)"
    dc ps >/dev/null 2>&1 || fail "cannot talk to the compose stack at $TWOW_COMPOSE_FILE"
}

# A single-value query against a schema, run inside the db container so no
# client is needed on the host and no port has to be published.
dbq() {
    _schema="$1"; shift
    # MYSQL_PWD rather than --password: the password would otherwise be visible
    # in the container's process list to anything else running in it.
    dc exec -T -e MYSQL_PWD="$TWOW_DB_PASSWORD" "$TWOW_DB_SERVICE" mariadb \
        --user="$TWOW_DB_USER" \
        --batch --raw --skip-column-names --database="$_schema" \
        --execute="$*" 2>/dev/null
}

# TCP reachability without assuming any one tool is present. bash's /dev/tcp is
# deliberately last: this suite is /bin/sh and may run under dash.
tcp_probe() {
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 3 "$1" "$2" >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import socket,sys; s=socket.create_connection((sys.argv[1],int(sys.argv[2])),3); s.close()' \
            "$1" "$2" >/dev/null 2>&1
    elif command -v bash >/dev/null 2>&1; then
        bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1
    else
        return 2
    fi
}

# Poll a command until it succeeds. Returns 1 on timeout so callers decide
# whether that is a FAIL or a SKIP.
wait_for() {
    _deadline=$(( $(date +%s) + ${1:-$TWOW_TIMEOUT} )); shift
    while [ "$(date +%s)" -lt "$_deadline" ]; do
        if "$@"; then return 0; fi
        sleep 2
    done
    return 1
}

# Client data (dbc/maps/vmaps/mmaps) is extracted from a game client and is
# never in an image or in Git (ADR-0023). Without it mangosd cannot load a
# single map, so every world-server check is unprovable rather than failing.
have_client_data() {
    case "$TWOW_CLIENT_DATA" in
        1|true|yes) return 0 ;;
        0|false|no) return 1 ;;
    esac
    dc exec -T "$TWOW_WORLD_SERVICE" sh -c \
        "[ -d '$TWOW_DATA_DIR/maps' ] && [ -d '$TWOW_DATA_DIR/dbc' ]" >/dev/null 2>&1
}

require_client_data() {
    have_client_data || skip \
        "no client data mounted - the world server cannot start, so this check cannot run (ADR-0023)"
}
