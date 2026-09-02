#!/bin/sh
# mangosd reads its interactive console from stdin and treats EOF as "shut down".
# A container started without a TTY therefore exits immediately, which is the
# single most common way this server fails to run under Docker.
#
# The fix is a FIFO held open read-write for the lifetime of the container: it
# never delivers EOF, and it doubles as the console. An operator (or a health
# check, or a deploy job) can drive the running server with:
#
#     echo "server info" > /opt/turtle/run/mangosd.in
#
# SIGTERM is translated into a graceful in-game shutdown rather than a kill, so
# `docker stop` saves player and bot state instead of truncating it.
set -eu

PREFIX="${PREFIX:-/opt/turtle}"
FIFO="${MANGOSD_FIFO:-${PREFIX}/run/mangosd.in}"
CONF="${MANGOSD_CONF:-${PREFIX}/etc/mangosd.conf}"
SHUTDOWN_GRACE="${MANGOSD_SHUTDOWN_GRACE:-30}"

[ -p "$FIFO" ] || { rm -f "$FIFO"; mkfifo -m 0600 "$FIFO"; }

# fd 3 keeps a writer attached forever, so the reader never sees EOF.
exec 3<> "$FIFO"

mangosd_pid=""

graceful_stop() {
    [ -n "$mangosd_pid" ] || exit 0
    echo "[entrypoint] SIGTERM: saving world and shutting down gracefully" >&2
    printf 'saveall\n' >&3 || true
    printf 'server shutdown 0\n' >&3 || true

    i=0
    while [ "$i" -lt "$SHUTDOWN_GRACE" ]; do
        kill -0 "$mangosd_pid" 2>/dev/null || { echo "[entrypoint] clean shutdown" >&2; exit 0; }
        i=$((i + 1))
        sleep 1
    done

    # Deliberately not SIGKILL: a hard kill here is how databases and character
    # state get corrupted. Report the failure instead and let the operator see it.
    echo "[entrypoint] world did not stop within ${SHUTDOWN_GRACE}s; sending SIGTERM" >&2
    kill -TERM "$mangosd_pid" 2>/dev/null || true
    wait "$mangosd_pid" 2>/dev/null || true
    exit 1
}
trap graceful_stop TERM INT

if [ ! -f "$CONF" ]; then
    echo "[entrypoint] no config at $CONF" >&2
    echo "[entrypoint] mount one, or copy ${PREFIX}/etc/mangosd.conf.dist and edit it" >&2
    exit 1
fi

# Seed the per-module configs a MODULES=static mangosd hard-requires.
#
# mangosd resolves each one as <directory of $CONF>/modules/<name>.conf and, on
# the first one it cannot open, prints
#
#     Could not load module configuration file .../modules/mod_bot_brain.conf: file could not be opened.
#     Could not load module configuration files.
#
# and exits before it reaches the database. What `cmake --install` puts in that
# directory is the template -- `<name>.conf.dist`, see CopyModuleConfig in
# core/cmake/ConfigureModules.cmake -- and nothing anywhere renames it. So every
# image built with modules linked in ships the six templates and none of the six
# files the server actually opens, and will not start.
#
# Verified against a MODULES=static build of this tree: with the .conf files
# absent mangosd prints exactly the two lines above and stops; with them present
# it proceeds and the next thing it reports is the database connection.
#
# Copy, never overwrite: an operator or a bind mount that supplies its own
# <name>.conf keeps it, the same way $CONF above is left alone when it exists.
# Every .dist ships its module switched off, so seeding changes no behaviour --
# it only stops the server dying on a file nothing was ever told to create.
MODULE_CONF_DIR="$(dirname "$CONF")/modules"
if [ -d "$MODULE_CONF_DIR" ]; then
    for dist in "$MODULE_CONF_DIR"/*.conf.dist; do
        [ -f "$dist" ] || continue
        conf="${dist%.dist}"
        [ -f "$conf" ] && continue
        cp "$dist" "$conf"
        echo "[entrypoint] seeded $(basename "$conf") from its .dist template" >&2
    done
fi

echo "[entrypoint] starting mangosd (console FIFO: $FIFO)" >&2
"${PREFIX}/bin/mangosd" -c "$CONF" <&3 &
mangosd_pid=$!
wait "$mangosd_pid"
