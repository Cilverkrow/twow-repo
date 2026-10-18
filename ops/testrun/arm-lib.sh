# shellcheck shell=bash
# Test-arm shim for slot jobs (R07a). Source it after setting the track variables:
#   RT_ROOT  track folder (e.g. /y/tw/builds/ob30-t9-bisect/cap-threads)
#   RT_F     compose file of the track     RT_P  compose project     RT_C  mangosd container
#   RT_REF   reference render (planned live: deploy base + live switch list, rendered by run-config.sh)
#   RT_ENV   environment overlay of the track (DB, realm id, roster files); declared, versioned
#   RT_KNOWN optional: template files for unknown-key checks (space separated)
#   RT_ENV_FILES optional: extra files of the track copied into every render (e.g. roster-guilds.tsv), space separated, no spaces in paths
# Usage in a job:
#   rt_arm_begin <slot> <arm-label>      new arm overlay (empty)
#   setb KEY VALUE / setk KEY VALUE      write into the arm overlay (not into runtime-config any more)
#   rt_arm_up [extra compose -f files…]  render -> diff -> override -> compose up -> verify; exports RT_RUNCFG
#   rt_arm_check                         verify again (call at measurement end); 0 = still identical
# Every step logs one line to $RT_ROOT/threads.out; failures return non-zero and write flags/RT-FAIL-<arm>.
RT_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RT_TOOL="$RT_LIB_DIR/run-config.sh"

rt_log() { echo "RT $* $(date -u +%TZ)" >> "$RT_ROOT/threads.out"; }
# Messages may quote tool output; anything shaped like a connection string is masked before it reaches flags or threads.out.
rt_clean() { sed -E 's/"?[^";[:space:]]*;[0-9]*;[^;[:space:]]*;[^;[:space:]]*;[^"[:space:]]*"?/<secret>/g'; }
rt_fail() { local m; m=$(printf '%s' "$2" | rt_clean); echo "$(date -u +%FT%TZ) $m" > "$RT_ROOT/flags/RT-FAIL-$1"; rt_log "FAIL $1: $m"; return 1; }

rt_arm_begin() {
    : "${RT_ROOT:?}" "${RT_REF:?}" "${RT_ENV:?}"
    RT_SLOT=$1; RT_ARM=$2; RT_RUN="$RT_ROOT/runs/$1-$2-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$RT_RUN"; : > "$RT_RUN/arm.overlay"; RT_RUNCFG=""
    export RT_SLOT RT_ARM RT_RUN RT_RUNCFG
}

# Replace-or-append KEY in the arm overlay; the target file is resolved at render time.
rt_set() {
    [ -n "${RT_RUN:-}" ] || { echo "rt_set before rt_arm_begin" >&2; return 1; }
    local o="$RT_RUN/arm.overlay"
    K=$1 awk 'BEGIN{k=ENVIRON["K"]} { t=$0; sub(/^[[:space:]]*/,"",t); if (index(t,k)==1 && substr(t,length(k)+1) ~ /^[[:space:]]*=/) next; print }' "$o" > "$o.tmp"
    printf '%s = %s\n' "$1" "$2" >> "$o.tmp"; mv "$o.tmp" "$o"
}
setb() { rt_set "$1" "$2"; }
setk() { rt_set "$1" "$2"; }

rt_arm_up() {
    local k=() t; for t in ${RT_KNOWN:-}; do k+=(--known "$t"); done
    for t in ${RT_ENV_FILES:-}; do k+=(--add-file "$t"); done
    local r; r=$(bash "$RT_TOOL" render --base "$RT_REF" --out "$RT_RUN/config" "${k[@]}" "$RT_ENV" "$RT_RUN/arm.overlay" 2> "$RT_RUN/render.err") \
        || { rt_fail "$RT_ARM" "render failed: $(tr '\n' ' ' < "$RT_RUN/render.err" | cut -c1-300)"; return 1; }
    bash "$RT_TOOL" diff --ref "$RT_REF" --run "$RT_RUN/config" --declared "$RT_ENV" --declared "$RT_RUN/arm.overlay" > "$RT_RUN/diff.tsv" \
        || { rt_fail "$RT_ARM" "undeclared deviation ($(tail -1 "$RT_RUN/diff.tsv"))"; return 1; }
    bash "$RT_TOOL" override --run "$RT_RUN/config" --like "$RT_F" --base "$RT_ROOT/runtime-config" -o "$RT_RUN/override.yml" > /dev/null \
        || { rt_fail "$RT_ARM" "override failed"; return 1; }
    local fs=(-f "$RT_F" -f "$RT_RUN/override.yml") x; for x in "$@"; do fs+=(-f "$x"); done
    docker compose "${fs[@]}" -p "$RT_P" config --quiet || { rt_fail "$RT_ARM" "compose config failed"; return 1; }
    docker compose "${fs[@]}" -p "$RT_P" up -d --force-recreate > /dev/null 2>&1
    sleep 5; [ -n "$(docker ps -q --filter "name=^$RT_C$")" ] || { rt_fail "$RT_ARM" "container not running after up"; return 1; }
    bash "$RT_TOOL" verify --container "$RT_C" --run "$RT_RUN/config" --base "$RT_ROOT/runtime-config" > "$RT_RUN/verify-start.txt" 2>&1 \
        || { rt_fail "$RT_ARM" "verify at start: $(tr '\n' ' ' < "$RT_RUN/verify-start.txt" | cut -c1-200)"; return 1; }
    RT_RUNCFG=$(awk '$2=="RUNCFG"{print $1}' "$RT_RUN/config/RUNCFG.sha256"); export RT_RUNCFG
    RT_IMG=$(docker inspect "$RT_C" --format '{{.Image}}' | sed 's/^sha256://' | cut -c1-12); export RT_IMG
    rt_log "arm $RT_SLOT/$RT_ARM up cfg=${RT_RUNCFG:0:12} img=$RT_IMG $(tail -1 "$RT_RUN/diff.tsv") run=$RT_RUN ($r)"
}

# 0 = config unchanged; 1 = mounted config changed/not read-only (arm INVALID); 5 = container not running at the end.
rt_arm_check() {
    local rc=0
    bash "$RT_TOOL" verify --container "$RT_C" --run "$RT_RUN/config" --base "$RT_ROOT/runtime-config" > "$RT_RUN/verify-end.txt" 2>&1 || rc=$?
    case $rc in
        0) rt_log "arm $RT_SLOT/$RT_ARM verify end OK cfg=${RT_RUNCFG:0:12}"; return 0;;
        5) rt_fail "$RT_ARM" "container not running at measurement end - arm INVALID (crash/stop, not a config change)"; return 5;;
        *) rt_fail "$RT_ARM" "verify at end - mounted config changed or not read-only - arm INVALID"; return 1;;
    esac
}
