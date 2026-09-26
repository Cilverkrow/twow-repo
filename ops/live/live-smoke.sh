#!/usr/bin/env bash
# Read-only smoke for the LIVE Docker stack (#36).
#
# test/smoke is written for a disposable stack: 40-shutdown.sh stops the server
# and 20-console.sh writes to the console, so it must never be pointed at live.
# This script only reads: `docker inspect`/`docker port`, a TCP connect to the
# published ports, the mounted gameplay logs, and (optionally) SELECTs through
# the database container. It is meant both as a routine check and as the
# acceptance check right after a deploy or a roster reset.
#
# Logs are identified per run, not by byte offset: mangosd writes a new
# server_<UTC timestamp>.log on every start and truncates the csv logs, so the
# run is the server log whose name matches the container start and whose first
# line hash stays the same over the observation window.
#
# Usage:
#   TWOW_LIVE_PROJECT=ws50-roster-v6-136-dccbe71d ops/live/live-smoke.sh
#   ops/live/live-smoke.sh --classify <server.log>   # triage only
#
# Environment (defaults in brackets):
#   TWOW_LIVE_PROJECT            compose project of the live stack (required)
#   TWOW_LIVE_EXPECT_DIGEST      sha256:... the announced image digest [unchecked]
#   TWOW_LIVE_WINDOW             observation window in seconds [60]
#   TWOW_LIVE_ROSTER_SIZE        persistent roster size [136]
#   TWOW_LIVE_MAX_LEVEL          fail if a roster bot is above this level
#                                (post-reset acceptance, e.g. 2) [unchecked]
#   TWOW_LIVE_REQUIRE_BOT_BRAIN  1 = the BotBrain handshake must be logged [1]
#   TWOW_LIVE_LOG_DIR            host path of /var/log/turtle [from the mount]
#   TWOW_LIVE_DB_CONTAINER       database container for the roster SELECTs
#   TWOW_LIVE_DB_DEFAULTS_FILE   host path of a MariaDB option file ([client]
#                                user/password). It is streamed to the client
#                                on stdin and never printed or put on a command
#                                line.
#   TWOW_LIVE_DB_FROM_CONF       instead: a mangosd.conf whose
#                                CharacterDatabase.Info supplies user/password,
#                                piped to the client from memory the same way
#   TWOW_LIVE_DB_FROM_LIVE_CONF  1 = use the mangosd.conf mounted into the live
#                                mangosd container [0]. Reading the live
#                                credentials was approved by the owner on
#                                2026-09-25 (#36): SELECT only, never output.
#   TWOW_CHAR_SCHEMA             character schema [tw_char]
#   TWOW_LIVE_REQUIRE_ROSTER     1 = without database access the verdict is
#                                SKIP, because "136 online" cannot be proven
#                                from the logs alone [1]
#   TWOW_LIVE_EVIDENCE_DIR       also write the report here
#   TWOW_LIVE_TRIAGE             triage rules [error-triage.tsv next to this
#                                script]; set it when running a copy
#   TWOW_LIVE_PERF_MAX_MS        fail if a logged "Update map system" of this
#                                run took longer [3000] (D1 interim rule, #351)
#   TWOW_LIVE_PERF_WARMUP_S      seconds after world-up left out of that maximum
#                                and reported separately [300]
#
# Exit codes as in test/smoke: 0 PASS, 1 FAIL, 77 SKIP (reason printed).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TRIAGE=${TWOW_LIVE_TRIAGE:-$HERE/error-triage.tsv}
[[ -f "$TRIAGE" ]] || {
    echo "ERROR: triage rules not found: $TRIAGE (run ops/live/live-smoke.sh from the repository, or set TWOW_LIVE_TRIAGE)" >&2
    exit 2
}
MARKER_RE='(^|[^[:alpha:]])([Ee][Rr][Rr][Oo][Rr]|[Ff][Aa][Tt][Aa][Ll]|[Cc][Rr][Aa][Ss][Hh]|[Aa][Ss][Ss][Ee][Rr][Tt])'

# ---------------------------------------------------------------- triage ----
# classify_markers <server.log> -> "class<TAB>count" lines, then "unknown<TAB>
# <normalized message>" examples. Phase boundary: first "World server is up".
classify_markers() {
    local log=$1 up
    up=$(grep -m1 'World server is up and running' "$log" | cut -c1-19 || true)
    grep -E "$MARKER_RE" "$log" | awk -v up="$up" -v rules="$TRIAGE" '
        BEGIN {
            FS = "\t"
            while ((getline line < rules) > 0) {
                if (line ~ /^#/ || line ~ /^[[:space:]]*$/) continue
                split(line, f, "\t")
                n++; cls[n] = f[1]; phase[n] = f[2]; re[n] = f[3]
            }
            close(rules)
            if (n == 0) { print "ERROR: no triage rules in " rules > "/dev/stderr"; exit 2 }
        }
        {
            ts = substr($0, 1, 19)
            msg = $0
            if (ts ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$/) msg = substr($0, 21)
            p = (up != "" && ts >= up) ? "runtime" : "startup"
            low = tolower(msg)
            hit = "unknown"
            for (i = 1; i <= n; i++) {
                if (phase[i] != "any" && phase[i] != p) continue
                if (low ~ re[i]) { hit = cls[i]; break }
            }
            count[hit]++
            if (hit == "unknown" || hit == "fatal") {
                norm = msg; gsub(/[0-9]+/, "N", norm)
                example[hit "\t" p ":" norm]++
            }
        }
        END {
            split("fatal known-data known-runtime known-bot unknown", order, " ")
            for (k = 1; k <= 5; k++) printf "%s\t%d\n", order[k], count[order[k]] + 0
            for (e in example) printf "example\t%s\t%d\n", e, example[e]
        }'
}

if [[ "${1:-}" == --classify ]]; then
    [[ -f "${2:-}" ]] || { echo "usage: $0 --classify <server.log>" >&2; exit 2; }
    out=$(classify_markers "$2")
    printf '%s\n' "$out"
    fatal=$(awk -F'\t' '$1=="fatal"{print $2}' <<<"$out")
    unknown=$(awk -F'\t' '$1=="unknown"{print $2}' <<<"$out")
    [[ "$fatal" == 0 && "$unknown" == 0 ]]
    exit $?
fi

# ------------------------------------------------------------------ setup ----
PROJECT=${TWOW_LIVE_PROJECT:?TWOW_LIVE_PROJECT (compose project of the live stack) is required}
WINDOW=${TWOW_LIVE_WINDOW:-60}
ROSTER_SIZE=${TWOW_LIVE_ROSTER_SIZE:-136}
MAX_LEVEL=${TWOW_LIVE_MAX_LEVEL:-}
REQUIRE_BOT_BRAIN=${TWOW_LIVE_REQUIRE_BOT_BRAIN:-1}
REQUIRE_ROSTER=${TWOW_LIVE_REQUIRE_ROSTER:-1}
EXPECT_DIGEST=${TWOW_LIVE_EXPECT_DIGEST:-}
CHAR_SCHEMA=${TWOW_CHAR_SCHEMA:-tw_char}
DB_CONTAINER=${TWOW_LIVE_DB_CONTAINER:-}
DB_DEFAULTS=${TWOW_LIVE_DB_DEFAULTS_FILE:-}
[[ "$WINDOW" =~ ^[0-9]+$ && "$ROSTER_SIZE" =~ ^[0-9]+$ ]] || { echo "ERROR: WINDOW and ROSTER_SIZE must be integers" >&2; exit 2; }
[[ -z "$MAX_LEVEL" || "$MAX_LEVEL" =~ ^[0-9]+$ ]] || { echo "ERROR: TWOW_LIVE_MAX_LEVEL must be an integer" >&2; exit 2; }
command -v docker >/dev/null || { echo "LIVE_SMOKE=SKIP reason=docker CLI not available"; exit 77; }

REPORT=$(mktemp)
trap 'rm -f "$REPORT"' EXIT
FAILS=0
SKIPS=()
emit() { printf '%s\n' "$*" | tee -a "$REPORT"; }
check() {  # check <name> PASS|FAIL|SKIP <detail>
    emit "CHECK $1 $2 $3"
    case $2 in FAIL) FAILS=$((FAILS + 1)) ;; SKIP) SKIPS+=("$1") ;; esac
}

container_for() {
    docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
        --filter "label=com.docker.compose.service=$1" --format '{{.Names}}' | head -n 1
}
state() { docker inspect -f "$2" "$1"; }

emit "LIVE_SMOKE_PROJECT=$PROJECT"
emit "LIVE_SMOKE_STARTED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ------------------------------------------------------------- containers ----
declare -A CNAME RESTARTS0 STARTED0
for svc in mangosd realmd; do
    c=$(container_for "$svc")
    if [[ -z "$c" ]]; then check "container.$svc" FAIL "no container for service $svc in $PROJECT"; continue; fi
    CNAME[$svc]=$c
    running=$(state "$c" '{{.State.Running}}')
    RESTARTS0[$svc]=$(state "$c" '{{.RestartCount}}')
    STARTED0[$svc]=$(state "$c" '{{.State.StartedAt}}')
    [[ "$running" == true ]] && check "container.$svc" PASS "$c running since ${STARTED0[$svc]} restarts=${RESTARTS0[$svc]}" \
                             || check "container.$svc" FAIL "$c not running"
    if [[ -n "$EXPECT_DIGEST" ]]; then
        digests=$(docker image inspect "$(state "$c" '{{.Image}}')" --format '{{join .RepoDigests " "}}')
        [[ " $digests " == *"@$EXPECT_DIGEST "* ]] && check "digest.$svc" PASS "$EXPECT_DIGEST" \
                                                  || check "digest.$svc" FAIL "expected $EXPECT_DIGEST, image has: ${digests:-none}"
    else
        check "digest.$svc" SKIP "TWOW_LIVE_EXPECT_DIGEST not set"
    fi
done

# ------------------------------------------------------------------ ports ----
probe_port() {  # probe_port <name> <container> <container-port>
    local name=$1 c=$2 port=$3 maps addr host hport
    maps=$(docker port "$c" "$port/tcp" 2>/dev/null | grep -v '^\[::\]' || true)
    if [[ $(grep -c . <<<"$maps") -ne 1 ]]; then
        check "port.$name" FAIL "expected exactly one published binding for $port/tcp, got: ${maps:-none}"
        return
    fi
    addr=${maps##* }; host=${addr%:*}; hport=${addr##*:}
    [[ "$host" == 0.0.0.0 ]] && host=127.0.0.1
    if timeout 5 bash -c "exec 3<>/dev/tcp/$host/$hport" 2>/dev/null; then
        check "port.$name" PASS "$port/tcp -> $host:$hport accepts connections"
    else
        check "port.$name" FAIL "$port/tcp -> $host:$hport does not accept connections"
    fi
}
[[ -n "${CNAME[realmd]:-}" ]] && probe_port realmd "${CNAME[realmd]}" 3724
[[ -n "${CNAME[mangosd]:-}" ]] && probe_port world "${CNAME[mangosd]}" 8090

# ------------------------------------------------------------ run identity ----
LOG_DIR=${TWOW_LIVE_LOG_DIR:-}
if [[ -z "$LOG_DIR" && -n "${CNAME[mangosd]:-}" ]]; then
    LOG_DIR=$(state "${CNAME[mangosd]}" '{{range .Mounts}}{{if eq .Destination "/var/log/turtle"}}{{.Source}}{{end}}{{end}}')
fi
SERVER_LOG=""
if [[ -n "$LOG_DIR" && -d "$LOG_DIR" && -n "${STARTED0[mangosd]:-}" ]]; then
    start_epoch=$(date -u -d "${STARTED0[mangosd]}" +%s)
    # The newest server log whose name is not older than the container start
    # (minus clock slack): the log of THIS run, whatever happened to earlier ones.
    while IFS= read -r f; do
        stamp=$(basename "$f" .log); stamp=${stamp#server_}
        stamp_epoch=$(date -u -d "${stamp:0:10} ${stamp:11:2}:${stamp:14:2}:${stamp:17:2}" +%s 2>/dev/null || echo 0)
        if (( stamp_epoch >= start_epoch - 120 )); then SERVER_LOG=$f; fi
    done < <(ls -1 "$LOG_DIR"/server_*.log 2>/dev/null | sort)
fi
if [[ -z "$SERVER_LOG" ]]; then
    check run.log FAIL "no server_<timestamp>.log for the container start ${STARTED0[mangosd]:-?} in ${LOG_DIR:-<unknown>}"
else
    first_hash() { head -n 1 "$1" | sha256sum | cut -c1-16; }
    ID0=$(first_hash "$SERVER_LOG")
    check run.log PASS "$(basename "$SERVER_LOG") first-line=$ID0"
fi

# -------------------------------------------------------------- behaviour ----
if [[ -n "$SERVER_LOG" ]]; then
    grep -q 'World server is up and running' "$SERVER_LOG" \
        && check world.up PASS "$(grep -m1 'World server is up and running' "$SERVER_LOG" | cut -c1-19)" \
        || check world.up FAIL "no 'World server is up and running' in this run"
    if [[ "$REQUIRE_BOT_BRAIN" == 1 ]]; then
        grep -q 'mod-bot-brain: contract handshake OK' "$SERVER_LOG" \
            && check bot_brain.handshake PASS "contract handshake OK" \
            || check bot_brain.handshake FAIL "no BotBrain contract handshake in this run"
    fi
    loaded=$(grep -o '\[PersistentRoster\] loaded version [0-9]* with [0-9]* ordered GUIDs' "$SERVER_LOG" | tail -n 1 || true)
    n=$(sed -E 's/.* with ([0-9]+) ordered GUIDs/\1/' <<<"$loaded")
    if [[ -z "$loaded" ]]; then check roster.loaded FAIL "no [PersistentRoster] loaded line"
    elif [[ "$n" == "$ROSTER_SIZE" ]]; then check roster.loaded PASS "${loaded#\[PersistentRoster\] }"
    else check roster.loaded FAIL "roster has $n GUIDs, expected $ROSTER_SIZE"; fi
fi

# ------------------------------------------------------------ observation ----
# Liveness: the server log of this run and bot_events.csv are written all the
# time while the world ticks and bots act. perf.log is not a heartbeat - it only
# records slow map updates, so a fast healthy server may leave it untouched.
size_of() { [[ -n "$1" && -f "$1" ]] && wc -c < "$1" | tr -d ' ' || echo 0; }
LIVE0=$(( $(size_of "$SERVER_LOG") + $(size_of "$LOG_DIR/bot_events.csv") ))
T0=$(date -u +'%Y-%m-%d %H:%M:%S')
emit "LIVE_SMOKE_WINDOW_SECONDS=$WINDOW"
sleep "$WINDOW"
T1=$(date -u +'%Y-%m-%d %H:%M:%S')

for svc in mangosd realmd; do
    c=${CNAME[$svc]:-}; [[ -z "$c" ]] && continue
    r1=$(state "$c" '{{.RestartCount}}'); s1=$(state "$c" '{{.State.StartedAt}}')
    if [[ "$r1" == "${RESTARTS0[$svc]}" && "$s1" == "${STARTED0[$svc]}" ]]; then
        check "stable.$svc" PASS "no restart in ${WINDOW}s"
    else
        check "stable.$svc" FAIL "restarted during the window (restarts ${RESTARTS0[$svc]}->$r1)"
    fi
done
if [[ -n "$SERVER_LOG" ]]; then
    [[ "$(first_hash "$SERVER_LOG")" == "$ID0" ]] && check run.same PASS "same run over the window" \
        || check run.same FAIL "server log was replaced or truncated during the window"
fi
LIVE1=$(( $(size_of "$SERVER_LOG") + $(size_of "$LOG_DIR/bot_events.csv") ))
(( LIVE1 > LIVE0 )) && check world.loop PASS "server log + bot_events grew by $(( LIVE1 - LIVE0 )) bytes" \
                    || check world.loop FAIL "neither the server log nor bot_events.csv grew in ${WINDOW}s"

# Bots acting in the window, and each bot's latest level in this run.
EVENTS="$LOG_DIR/bot_events.csv"
if [[ -f "$EVENTS" ]]; then
    active=$(awk -F, -v t0="$T0" -v t1="$T1" 'substr($1,1,19) >= t0 && substr($1,1,19) <= t1 { seen[$2] = 1 } END { print length(seen) }' "$EVENTS")
    (( active > 0 )) && check bots.active PASS "$active distinct bots logged events in the window" \
                     || check bots.active FAIL "no bot event in ${WINDOW}s"
    # Column 7 is the level with progress (9.33 = level 9); position is quoted.
    levels=$(awk -F'"' '{ n = split($3, f, ","); name_line = $1; split(name_line, a, ","); lvl[a[2]] = int(f[4]) }
                        END { for (b in lvl) h[lvl[b]]++; for (l in h) printf "%s:%d ", l, h[l] }' "$EVENTS" | tr ' ' '\n' | sort -n | tr '\n' ' ')
    emit "LOG_LEVEL_DISTRIBUTION=${levels% } (latest event per bot, log proxy)"
else
    check bots.active FAIL "no bot_events.csv in $LOG_DIR"
fi

# --------------------------------------------------------------- database ----
# The client options reach the database container only through a pipe: from
# TWOW_LIVE_DB_DEFAULTS_FILE, or built in memory from CharacterDatabase.Info
# ("host;port;user;password;schema") of the live mangosd.conf. Never a file,
# a command-line argument, an environment variable or a line of output.
db_options() {
    if [[ -n "$DB_DEFAULTS" ]]; then cat -- "$DB_DEFAULTS"; return; fi
    local info user pass
    info=$(awk '/^[[:space:]]*CharacterDatabase\.Info[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); sub(/[[:space:]\r]+$/, ""); print; exit }' "$DB_FROM_CONF")
    IFS=';' read -r _ _ user pass _ <<<"$info"
    pass=${pass//\\/\\\\}; pass=${pass//\"/\\\"}
    printf '[client]\nuser="%s"\npassword="%s"\n' "$user" "$pass"
}
DB_FROM_CONF=${TWOW_LIVE_DB_FROM_CONF:-}
if [[ -z "$DB_FROM_CONF" && "${TWOW_LIVE_DB_FROM_LIVE_CONF:-0}" == 1 && -n "${CNAME[mangosd]:-}" ]]; then
    DB_FROM_CONF=$(state "${CNAME[mangosd]}" '{{range .Mounts}}{{if eq .Destination "/opt/turtle/etc/mangosd.conf"}}{{.Source}}{{end}}{{end}}')
fi
if [[ -n "$DB_CONTAINER" && ( ( -n "$DB_DEFAULTS" && -f "$DB_DEFAULTS" ) || ( -n "$DB_FROM_CONF" && -f "$DB_FROM_CONF" ) ) ]]; then
    emit "DB_ACCESS=$([[ -n "$DB_DEFAULTS" ]] && echo option-file || echo "CharacterDatabase.Info of $(basename "$DB_FROM_CONF")") via $DB_CONTAINER (SELECT only)"
    sql() { db_options | docker exec -i "$DB_CONTAINER" mariadb --defaults-extra-file=/dev/stdin --protocol=tcp --host=127.0.0.1 --batch --skip-column-names "$CHAR_SCHEMA" -e "$1"; }
    roster_join="FROM ai_playerbot_roster_current c JOIN ai_playerbot_roster_member m ON m.version_id = c.version_id LEFT JOIN characters ch ON ch.guid = m.character_guid WHERE c.singleton_id = 1"
    if row=$(sql "SELECT COUNT(*), COUNT(ch.guid), COALESCE(SUM(ch.online), 0), COALESCE(MAX(ch.level), 0) $roster_join;" 2>/dev/null); then
        read -r members present online maxlvl <<<"$row"
        dist=$(sql "SELECT ch.level, COUNT(*) $roster_join GROUP BY ch.level ORDER BY ch.level;" | awk '{printf "%s:%s ", $1, $2}')
        emit "DB_LEVEL_DISTRIBUTION=${dist% }"
        [[ "$members" == "$ROSTER_SIZE" && "$present" == "$ROSTER_SIZE" ]] \
            && check roster.members PASS "$members members, all characters present" \
            || check roster.members FAIL "members=$members characters=$present expected $ROSTER_SIZE"
        [[ "$online" == "$ROSTER_SIZE" ]] && check roster.online PASS "$online/$ROSTER_SIZE online" \
                                          || check roster.online FAIL "$online/$ROSTER_SIZE online"
        if [[ -n "$MAX_LEVEL" ]]; then
            (( maxlvl <= MAX_LEVEL )) && check roster.max_level PASS "highest roster level $maxlvl <= $MAX_LEVEL" \
                                      || check roster.max_level FAIL "highest roster level $maxlvl > $MAX_LEVEL"
        fi
    else
        check roster.online FAIL "roster SELECT through $DB_CONTAINER failed"
    fi
else
    check roster.online SKIP "no database access (TWOW_LIVE_DB_CONTAINER + TWOW_LIVE_DB_DEFAULTS_FILE or TWOW_LIVE_DB_FROM_[LIVE_]CONF); online count not provable from logs"
    if [[ -n "$MAX_LEVEL" && -n "${levels:-}" ]]; then
        top=$(tr ' ' '\n' <<<"$levels" | awk -F: 'NF==2 && $1>m {m=$1} END {print m+0}')
        (( top <= MAX_LEVEL )) && check roster.max_level PASS "highest logged level $top <= $MAX_LEVEL (log proxy)" \
                               || check roster.max_level FAIL "highest logged level $top > $MAX_LEVEL (log proxy)"
    fi
fi

# ------------------------------------------------------------------- perf ----
# perf.log only records map-system updates slower than
# PerformanceLog.SlowMapSystemUpdate (default 100 ms), so it yields the maximum
# and the number of slow updates, never a tick p99 (#351). Only this run's
# lines count: those not older than the first line of its server log. As in
# the D1 gate (OB-00, 2026-09-26) the maximum excludes the warm-up after
# world-up, when every roster bot logs in at once; that peak is reported apart.
PERF_MAX_MS=${TWOW_LIVE_PERF_MAX_MS:-3000}
PERF_WARMUP_S=${TWOW_LIVE_PERF_WARMUP_S:-300}
up_line=$( [[ -n "$SERVER_LOG" ]] && grep -m1 'World server is up and running' "$SERVER_LOG" | cut -c1-19 || true)
if [[ -n "$SERVER_LOG" && -n "$up_line" && -f "$LOG_DIR/perf.log" ]]; then
    run_start=$(head -n 1 "$SERVER_LOG" | cut -c1-19)
    warm_end=$(date -u -d "$up_line $PERF_WARMUP_S seconds" +'%Y-%m-%d %H:%M:%S')
    read -r slow maxms warm_max <<<"$(awk -v s="$run_start" -v w="$warm_end" '
        substr($0, 1, 19) >= s && match($0, /Update map system: [0-9]+ms/) {
            v = substr($0, RSTART + 19, RLENGTH - 21) + 0; n++
            if (substr($0, 1, 19) < w) { if (v > wm) wm = v } else if (v > m) m = v }
        END { print n + 0, m + 0, wm + 0 }' "$LOG_DIR/perf.log")"
    hours=$(awk -v a="$(date -u -d "$run_start" +%s 2>/dev/null || echo 0)" -v b="$(date -u +%s)" \
        'BEGIN { h = (b - a) / 3600; printf "%.2f", (h > 0 ? h : 0) }')
    emit "PERF slow_map_updates=$slow max_ms=$maxms warmup_peak_ms=$warm_max (first ${PERF_WARMUP_S}s after world-up, info) run_hours=$hours (only updates > threshold are logged)"
    if [[ "$(date -u +'%Y-%m-%d %H:%M:%S')" < "$warm_end" ]]; then
        check perf.max_ms SKIP "still within ${PERF_WARMUP_S}s after world-up ($up_line)"
    else
        (( maxms <= PERF_MAX_MS )) && check perf.max_ms PASS "longest logged map update after warm-up ${maxms} ms <= ${PERF_MAX_MS} ms" \
                                   || check perf.max_ms FAIL "longest logged map update after warm-up ${maxms} ms > ${PERF_MAX_MS} ms"
    fi
else
    check perf.max_ms SKIP "no perf.log for this run in ${LOG_DIR:-<unknown>}"
fi

# ----------------------------------------------------------------- triage ----
if [[ -n "$SERVER_LOG" ]]; then
    tri=$(classify_markers "$SERVER_LOG")
    fatal=$(awk -F'\t' '$1=="fatal"{print $2}' <<<"$tri")
    unknown=$(awk -F'\t' '$1=="unknown"{print $2}' <<<"$tri")
    emit "TRIAGE $(awk -F'\t' '$1!="example"{printf "%s=%s ", $1, $2}' <<<"$tri")"
    awk -F'\t' '$1=="example"{printf "TRIAGE_EXAMPLE %s x%s: %s\n", $2, $4, $3}' <<<"$tri" | head -n 20 | tee -a "$REPORT"
    (( fatal == 0 )) && check triage.fatal PASS "0 fatal markers" || check triage.fatal FAIL "$fatal fatal markers"
    (( unknown == 0 )) && check triage.unknown PASS "0 unclassified markers" \
                       || check triage.unknown FAIL "$unknown unclassified markers: classify them in $(basename "$TRIAGE")"
fi

# ---------------------------------------------------------------- verdict ----
if (( FAILS > 0 )); then verdict=FAIL; code=1
elif [[ "$REQUIRE_ROSTER" == 1 && " ${SKIPS[*]:-} " == *" roster.online "* ]]; then
    verdict=SKIP; code=77
else verdict=PASS; code=0; fi
emit "LIVE_SMOKE=$verdict fails=$FAILS skipped=${SKIPS[*]:-none}"
if [[ -n "${TWOW_LIVE_EVIDENCE_DIR:-}" ]]; then
    mkdir -p "$TWOW_LIVE_EVIDENCE_DIR"
    cp "$REPORT" "$TWOW_LIVE_EVIDENCE_DIR/live-smoke-$(date -u +%Y%m%dT%H%M%SZ).txt"
fi
exit "$code"
