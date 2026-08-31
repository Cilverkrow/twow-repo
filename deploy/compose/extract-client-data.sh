#!/usr/bin/env bash
# Extract dbc/ maps/ vmaps/ mmaps/ from a game client into the mounted output.
#
# This exists because client data cannot legally or practically ship in an
# image: it is derived from a Turtle WoW 1.18.1 (build 7272) client the operator
# owns. Run it once; the output is then bind-mounted read-only into mangosd.
#
# It takes a long time. MoveMapGen alone is an hour or more.
#
# Each step is skipped if its output already exists, so an interrupted run
# resumes rather than starting over.
set -euo pipefail

CLIENT=${CLIENT:-/client}
OUT=${OUT:-/out}

log() { printf '[extract] %s\n' "$*" >&2; }

[ -d "$CLIENT/Data" ] || {
    log "no $CLIENT/Data -- point CLIENT_PATH at an installed game client directory"
    exit 1
}
mkdir -p "$OUT"

# The extractors resolve MPQs relative to the working directory, so they run
# inside the client. The client mount is read-only, hence the output juggling.
run_step() {
    local marker=$1; shift
    if [ -d "$OUT/$marker" ] && [ -n "$(ls -A "$OUT/$marker" 2>/dev/null)" ]; then
        log "skip $marker (already present)"
        return 0
    fi
    log "generating $marker ..."
    "$@"
}

WORK=/work/extract
mkdir -p "$WORK"
cd "$WORK"
# Symlink the client contents in: the tools want to run "inside" a client, and
# the real one is mounted read-only.
ln -sfn "$CLIENT/Data" "$WORK/Data"

move_out() { for d in "$@"; do [ -d "$WORK/$d" ] && { rm -rf "${OUT:?}/$d"; mv "$WORK/$d" "$OUT/$d"; }; done; }

# 1. dbc + maps
run_step dbc mapextractor
move_out dbc maps

# 2. vmaps: extractor then assembler
if [ ! -d "$OUT/vmaps" ] || [ -z "$(ls -A "$OUT/vmaps" 2>/dev/null)" ]; then
    log "generating vmaps ..."
    vmapextractor
    mkdir -p "$WORK/vmaps"
    vmap_assembler "$WORK/Buildings" "$WORK/vmaps"
    move_out vmaps
else
    log "skip vmaps (already present)"
fi

# 3. mmaps. The long one. MoveMapGen wants dbc/maps/vmaps beside it.
if [ ! -d "$OUT/mmaps" ] || [ -z "$(ls -A "$OUT/mmaps" 2>/dev/null)" ]; then
    log "generating mmaps -- expect an hour or more ..."
    for d in dbc maps vmaps; do ln -sfn "$OUT/$d" "$WORK/$d"; done
    mkdir -p "$WORK/mmaps"
    MoveMapGen
    move_out mmaps
else
    log "skip mmaps (already present)"
fi

# "Can't find area flag for areaid ..." warnings above are expected: a few ADT
# cells reference area ids absent from AreaTable.dbc.
log "done. Output in $OUT:"
ls -la "$OUT"
