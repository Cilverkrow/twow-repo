# shellcheck shell=bash
# Measurement lines for slot jobs (R07a). Source after arm-lib.sh (uses RT_ROOT, RT_SLOT, RT_ARM, RT_RUN, RT_RUNCFG, RT_IMG).
#   RT_CLASS   perf|behav (perf windows are only valid when isolated)
#   RT_PSI_DIR host PSI logs (psi-YYYYMMDD.log, one line per 10 s: "<ISO>Z cpu[some avg10=…] … io[some avg10=…]")
#   meas_start <planned-minutes> [reset-id] [roster-version]
#   meas_end                     -> MEAS end line with min=, isolated=, valid=; window.txt in the run folder
# Other tools read only these lines:
#   MEAS start slot=S arm=A class=C reset=R roster=V img=I cfg=H from=ISO plan=N
#   MEAS end slot=S arm=A class=C reset=R roster=V img=I cfg=H from=ISO to=ISO min=N isolated=yes|no valid=1|0 reason=…
# DISKLOAD lines ("DISKLOAD <who> <from>-<to>", ISO or HH:MM UTC) and PSI peaks (io some avg10 >= 20,
# cpu some avg10 >= 40) inside the window make it isolated=no.
RT_PSI_DIR=${RT_PSI_DIR:-/y/tw/evidence/ws-40/ob30-psi-host}
RT_CLASS=${RT_CLASS:-behav}

meas_start() {
    MEAS_PLAN=$1; MEAS_RESET=${2:--}; MEAS_ROSTER=${3:--}; MEAS_FROM=$(date -u +%FT%TZ)
    MEAS_HEAD="slot=${RT_SLOT:--} arm=${RT_ARM:--} class=$RT_CLASS reset=$MEAS_RESET roster=$MEAS_ROSTER img=${RT_IMG:--} cfg=${RT_RUNCFG:0:12}"
    [ -n "${RT_RUNCFG:-}" ] || MEAS_HEAD="${MEAS_HEAD}-"
    echo "MEAS start $MEAS_HEAD from=$MEAS_FROM plan=$MEAS_PLAN (host quiet please; disk-heavy work: write DISKLOAD <who> <from>-<to>)" >> "$RT_ROOT/threads.out"
}

# meas_confound FROM TO -> prints CONFOUNDED lines, returns 1 if any
meas_confound() {
    local f t l a b n=0 ts
    f=$(date -u -d "$1" +%s); t=$(date -u -d "$2" +%s)
    while IFS= read -r l; do
        read -r -a ts <<< "$(grep -oE '([0-9]{4}-[0-9]{2}-[0-9]{2}T)?[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?' <<< "$l" | tr '\n' ' ')"
        [ ${#ts[@]} -ge 2 ] || continue
        a=$(date -u -d "${ts[0]/T/ }Z" +%s 2>/dev/null) || continue; b=$(date -u -d "${ts[1]/T/ }Z" +%s 2>/dev/null) || continue
        if [ "$a" -lt "$t" ] && [ "$b" -gt "$f" ]; then echo "CONFOUNDED diskload: $l"; n=$((n + 1)); fi
    done < <(grep -E '^DISKLOAD ' "$RT_ROOT/threads.out")
    local p d
    for d in $(date -u -d @"$f" +%Y%m%d) $(date -u -d @"$t" +%Y%m%d); do echo "$RT_PSI_DIR/psi-$d.log"; done | sort -u | while read -r p; do
        [ -f "$p" ] || continue
        # ISO strings compare lexicographically (no mktime: mawk has no UTC mktime)
        awk -v f="$(date -u -d @"$f" +%FT%T)" -v t="$(date -u -d @"$t" +%FT%T)" '
            /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
                s = substr($0, 1, 19)
                if (s < f || s > t) next
                io = cpu = 0
                if (match($0, /io\[some avg10=[0-9.]+/)) io = substr($0, RSTART + 14, RLENGTH - 14) + 0
                if (match($0, /cpu\[some avg10=[0-9.]+/)) cpu = substr($0, RSTART + 15, RLENGTH - 15) + 0
                if (io >= 20 || cpu >= 40) print "CONFOUNDED psi: " substr($0, 1, 20) " cpu=" cpu " io=" io
            }' "$p"
    done | head -n 50
    [ $n -eq 0 ]
}

meas_end() {
    local to; to=$(date -u +%FT%TZ)
    local min=$(( ( $(date -u -d "$to" +%s) - $(date -u -d "$MEAS_FROM" +%s) ) / 60 ))
    local conf iso=yes valid=1 reason=ok
    conf=$(meas_confound "$MEAS_FROM" "$to" || true)
    [ -n "$conf" ] && iso=no
    if [ -n "${RT_RUN:-}" ] && declare -F rt_arm_check > /dev/null; then rt_arm_check || { valid=0; reason=config-changed; }; fi
    [ -n "${RT_RUNCFG:-}" ] || { valid=0; reason=no-runcfg; }
    [ "$RT_CLASS" = perf ] && [ $iso = no ] && [ $valid = 1 ] && { valid=0; reason=not-isolated; }
    [ "$min" -lt $(( MEAS_PLAN * 9 / 10 )) ] && [ $valid = 1 ] && { valid=0; reason=short; }
    local line="MEAS end $MEAS_HEAD from=$MEAS_FROM to=$to min=$min isolated=$iso valid=$valid reason=$reason"
    echo "$line" >> "$RT_ROOT/threads.out"
    if [ -n "${RT_RUN:-}" ]; then { echo "$line"; [ -n "$conf" ] && printf '%s\n' "$conf"; } >> "$RT_RUN/window.txt"; fi
    [ -n "$conf" ] && printf '%s\n' "$conf" | sed 's/^/MEAS /' >> "$RT_ROOT/threads.out"
    [ $valid = 1 ]
}
