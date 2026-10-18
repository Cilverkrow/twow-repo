#!/usr/bin/env bash
# One configuration truth per run (R07a, OB-00 18.10.2026; ADR-0038 render + hash).
#
#   run-config.sh render   --base DIR --out DIR [--known FILE]... [--add-file FILE]... [OVERLAY]...
#   run-config.sh diff     --ref DIR --run DIR [--declared OVERLAY]...
#   run-config.sh verify   --container NAME --run DIR [--base DIR]      (exit 4 mismatch, 5 container not running)
#   run-config.sh override --run DIR --target-dir PATH [--service NAME] [--file NAME=TARGET]... -o FILE
#   run-config.sh hash     DIR
#
# render copies every *.conf (and *.tsv) of the base folder, applies the overlays in
# order and writes RUNCFG.sha256 + keys.tsv. Overlay lines are "Key = Value". A key
# is replaced in place in the one file that holds it; a key that no base file holds
# is appended only if a --known template lists it (AiPlayerbot.* -> aiplayerbot.conf,
# BotBrain.* -> mod_bot_brain.conf, others -> mangosd.conf), otherwise it is an
# unknown key and render fails. Duplicate keys after render fail as well.
# diff compares every key of every .conf in --ref and --run. A differing key is
# "declared" when one of the --declared overlays sets it, otherwise UNDECLARED
# (exit 3). Secret values (database connection strings, passwords, tokens, API
# keys) are never printed; they show as <secret>.
# verify checks that every bind mount of the container whose source lies in --run is
# read-only and byte-identical inside the container, and that nothing from --base is
# mounted. Exit 4 on any mismatch.
set -euo pipefail

SECRET_RE='(Database\.?Info|Password|Passwd|Secret|Token|ApiKey|Api\.Key|LLM\.Key|\.Key$)'
# Values shaped like a connection string (host;port;user;pass;db) are masked whatever the key.
SECRET_VAL_RE='^"?[^;"]*;[0-9]*;[^;]*;[^;]*;'
die() { echo "run-config: $*" >&2; exit 2; }

# key<TAB>value for every active "Key = Value" line of a config file.
conf_kv() {
    awk '
        /^[[:space:]]*[#;]/ { next }
        match($0, /^[[:space:]]*[A-Za-z0-9_.]+[[:space:]]*=/) {
            k = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*/, "", k); sub(/[[:space:]]*=$/, "", k)
            v = substr($0, RSTART + RLENGTH); sub(/^[[:space:]]*/, "", v); sub(/[[:space:]\r]*$/, "", v)
            print k "\t" v
        }' "$1"
}

# Keys a template knows, including commented-out examples ("#Key = value").
known_keys() {
    awk 'match($0, /^[[:space:]]*#?[[:space:]]*[A-Za-z][A-Za-z0-9_.]*[[:space:]]*=/) {
            k = substr($0, RSTART, RLENGTH); sub(/^[[:space:]]*#?[[:space:]]*/, "", k); sub(/[[:space:]]*=$/, "", k); print k
        }' "$@"
}

mask() { # key value -> printable value
    if [[ $1 =~ $SECRET_RE || $2 =~ $SECRET_VAL_RE ]]; then echo "<secret>"; else printf '%s\n' "$2"; fi
}

hash_dir() { # writes RUNCFG.sha256 for all config files of DIR and prints the combined hash
    local d=$1 list
    list=$(cd "$d" && find . -maxdepth 1 -type f \( -name '*.conf' -o -name '*.tsv' \) ! -name 'keys.tsv' -printf '%f\n' | LC_ALL=C sort)
    [ -n "$list" ] || die "no config files in $d"
    (cd "$d" && printf '%s\n' "$list" | while IFS= read -r f; do sha256sum "$f"; done) > "$d/RUNCFG.files"
    local all; all=$(sha256sum < "$d/RUNCFG.files" | cut -c1-64)
    { cat "$d/RUNCFG.files"; echo "$all  RUNCFG"; } > "$d/RUNCFG.sha256"; rm -f "$d/RUNCFG.files"
    echo "$all"
}

cmd_render() {
    local base="" out="" known=() overlays=() addf=()
    while [ $# -gt 0 ]; do case $1 in
        --base) base=$2; shift 2;; --out) out=$2; shift 2;; --known) known+=("$2"); shift 2;; --add-file) addf+=("$2"); shift 2;;
        -*) die "render: unknown option $1";; *) overlays+=("$1"); shift;; esac; done
    [ -d "$base" ] || die "render: --base missing"; [ -n "$out" ] || die "render: --out missing"
    [ -e "$out" ] && die "render: $out exists (one folder per run)"
    mkdir -p "$out"
    find "$base" -maxdepth 1 -type f \( -name '*.conf' -o -name '*.tsv' \) ! -name 'keys.tsv' -exec cp -p {} "$out/" \;
    local a; for a in "${addf[@]}"; do [ -f "$a" ] || die "render: --add-file $a missing"; cp -p "$a" "$out/"; done
    local kf; kf=$(mktemp); trap 'rm -f "$kf"' RETURN
    [ ${#known[@]} -gt 0 ] && known_keys "${known[@]}" | LC_ALL=C sort -u > "$kf"
    local ov line k v f n err=0
    for ov in "${overlays[@]}"; do
        [ -f "$ov" ] || die "render: overlay $ov missing"
        local ln=0
        while IFS= read -r line || [ -n "$line" ]; do
            line=${line%$'\r'}; ln=$((ln + 1))
            [[ $line =~ ^[[:space:]]*($|#|\;) ]] && continue
            # line number only: an environment overlay holds connection strings, never echo its content
            [[ $line =~ ^[[:space:]]*([A-Za-z0-9_.]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || { echo "render: bad overlay line $ln in $(basename "$ov")" >&2; err=1; continue; }
            k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
            f=$(grep -lE "^[[:space:]]*${k//./\\.}[[:space:]]*=" "$out"/*.conf 2>/dev/null || true)
            n=$(printf '%s' "$f" | grep -c . || true)
            # A key some files share (e.g. BotBrain.Enable in mangosd.conf and mod_bot_brain.conf) is set to the same value in all of them.
            [ "$n" -gt 1 ] && echo "render: note: key $k set in $n files" >&2
            if [ "$n" -eq 0 ]; then
                if [ -s "$kf" ] && grep -qxF "$k" "$kf"; then
                    case $k in AiPlayerbot.*) f=$out/aiplayerbot.conf;; BotBrain.*) f=$out/mod_bot_brain.conf;; *) f=$out/mangosd.conf;; esac
                    [ -f "$f" ] || { echo "render: target $(basename "$f") for $k missing" >&2; err=1; continue; }
                    printf '%s = %s\n' "$k" "$v" >> "$f"; continue
                fi
                echo "render: UNKNOWN key $k (overlay $(basename "$ov"))" >&2; err=1; continue
            fi
            local tf
            while IFS= read -r tf; do
                K=$k V=$v awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
                    { line = $0; t = line; sub(/^[[:space:]]*/, "", t)
                      if (index(t, k) == 1 && substr(t, length(k) + 1) ~ /^[[:space:]]*=/) { print k " = " v; next }
                      print line }' "$tf" > "$tf.tmp" && mv "$tf.tmp" "$tf"
            done <<< "$f"
        done < "$ov"
    done
    local c
    for c in "$out"/*.conf; do
        conf_kv "$c" | cut -f1 | LC_ALL=C sort | uniq -d | sed "s|^|render: DUPLICATE key in $(basename "$c"): |" >&2
        [ -z "$(conf_kv "$c" | cut -f1 | LC_ALL=C sort | uniq -d)" ] || err=1
    done
    [ $err -eq 0 ] || { echo "render: FAILED, $out left for inspection" >&2; exit 3; }
    for c in "$out"/*.conf; do conf_kv "$c" | B=$(basename "$c") R=$SECRET_RE RV=$SECRET_VAL_RE awk -F'\t' '{ v = ($1 ~ ENVIRON["R"] || $2 ~ ENVIRON["RV"]) ? "<secret>" : $2; print ENVIRON["B"] "\t" $1 "\t" v }'; done > "$out/keys.tsv"
    local h; h=$(hash_dir "$out")
    chmod -R a-w "$out" 2>/dev/null || true
    echo "RUNCFG $h keys=$(wc -l < "$out/keys.tsv") overlays=${#overlays[@]}"
}

cmd_diff() {
    local ref="" run="" declared=()
    while [ $# -gt 0 ]; do case $1 in
        --ref) ref=$2; shift 2;; --run) run=$2; shift 2;; --declared) declared+=("$2"); shift 2;;
        *) die "diff: unknown argument $1";; esac; done
    [ -d "$ref" ] && [ -d "$run" ] || die "diff: --ref and --run must be folders"
    local dk; dk=$(mktemp); trap 'rm -f "$dk"' RETURN
    local o; for o in "${declared[@]}"; do conf_kv "$o"; done | cut -f1 | LC_ALL=C sort -u > "$dk"
    local f b und=0 total=0 out
    out=$(for f in "$ref"/*.conf "$run"/*.conf; do basename "$f"; done | LC_ALL=C sort -u | while IFS= read -r b; do
        join -t $'\t' -a1 -a2 -e '<absent>' -o '0,1.2,2.2' \
            <( [ -f "$ref/$b" ] && conf_kv "$ref/$b" | LC_ALL=C sort -t $'\t' -k1,1 ) \
            <( [ -f "$run/$b" ] && conf_kv "$run/$b" | LC_ALL=C sort -t $'\t' -k1,1 ) |
        while IFS=$'\t' read -r k a r; do
            [ "$a" = "$r" ] && continue
            if grep -qxF "$k" "$dk"; then s=declared; else s=UNDECLARED; fi
            printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$b" "$k" "$(mask "$k" "$a")" "$(mask "$k" "$r")"
        done
    done)
    [ -n "$out" ] && printf '%s\n' "$out"
    total=$(printf '%s' "$out" | grep -c . || true); und=$(printf '%s' "$out" | grep -c '^UNDECLARED' || true)
    echo "DIFF changed=$total undeclared=$und"
    [ "$und" -eq 0 ] || exit 3
}

cmd_verify() {
    local c="" run="" base=""
    while [ $# -gt 0 ]; do case $1 in
        --container) c=$2; shift 2;; --run) run=$2; shift 2;; --base) base=$2; shift 2;;
        *) die "verify: unknown argument $1";; esac; done
    [ -n "$c" ] && [ -d "$run" ] || die "verify: --container and --run needed"
    # A dead container is not a config change: own message and exit 5.
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || { echo "VERIFY DOWN container=$c not running"; exit 5; }
    local norm_run norm_base; norm_run=$(norm "$run"); norm_base=$([ -n "$base" ] && norm "$base" || true)
    local bad=0 seen=0 src dst rw h1 h2 ns
    while IFS=$'\t' read -r src dst rw; do
        ns=$(norm "$src")
        if [ -n "$norm_base" ] && [ "${ns#"$norm_base"/}" != "$ns" ]; then echo "verify: BASE MOUNTED $dst <- $src" >&2; bad=1; continue; fi
        [ "${ns#"$norm_run"/}" = "$ns" ] && continue
        seen=$((seen + 1))
        [ "$rw" = false ] || { echo "verify: NOT READ-ONLY $dst" >&2; bad=1; }
        h1=$(sha256sum < "$run/${ns#"$norm_run"/}" | cut -c1-64)
        h2=$(MSYS_NO_PATHCONV=1 docker exec "$c" sha256sum "$dst" 2>/dev/null | cut -c1-64)
        [ "$h1" = "$h2" ] || { echo "verify: MISMATCH $dst" >&2; bad=1; }
    done < <(docker inspect "$c" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\t"}}{{.Destination}}{{"\t"}}{{.RW}}{{"\n"}}{{end}}{{end}}')
    [ $seen -gt 0 ] || { echo "verify: no mount from $run in $c" >&2; bad=1; }
    local h; h=$(awk '$2=="RUNCFG"{print $1}' "$run/RUNCFG.sha256")
    [ $bad -eq 0 ] || { echo "VERIFY FAIL container=$c runcfg=${h:0:12}"; exit 4; }
    echo "VERIFY OK container=$c runcfg=${h:0:12} mounts=$seen"
}

# Lower-case, forward slashes, no drive colon and no /run/desktop prefix, symlink alias Y:/tw resolved.
norm() {
    local p=${1//\\//}; p=${p%/}
    p=$(printf '%s' "$p" | tr 'A-Z' 'a-z' | sed -E 's#^/run/desktop/mnt/host/##; s#^/mnt/##; s#^([a-z]):/#\1/#; s#^/([a-z])/#\1/#')
    printf '%s' "$p" | sed -E 's#^y/tw/#y/backup twwow/workspace-relocation-20260902/#'
}

# Rewrites every bind mount of COMPOSE whose source file lies in --base to the same file in --run,
# read-only, per service (inline-map and short syntax). Compose merges volumes by target,
# so "-f COMPOSE -f OUT" mounts the rendered run folder instead of the base.
cmd_override() {
    local run="" like="" base="" out=""
    while [ $# -gt 0 ]; do case $1 in
        --run) run=$2; shift 2;; --like) like=$2; shift 2;; --base) base=$2; shift 2;;
        -o) out=$2; shift 2;; *) die "override: unknown argument $1";; esac; done
    [ -d "$run" ] && [ -f "$like" ] && [ -d "$base" ] && [ -n "$out" ] || die "override: --run, --like, --base and -o needed"
    local src; src=$(cd "$run" && { pwd -W 2>/dev/null || pwd; })
    local nb; nb=$(norm "$base")
    local svc="" line s t f n=0 body=""
    while IFS= read -r line; do
        line=${line%$'\r'}
        [[ $line =~ ^\ \ ([A-Za-z0-9_-]+):[[:space:]]*$ ]] && { svc=${BASH_REMATCH[1]}; continue; }
        if [[ $line =~ source:[[:space:]]*\"([^\"]+)\".*target:[[:space:]]*([^,[:space:]}]+) ]]; then s=${BASH_REMATCH[1]}; t=${BASH_REMATCH[2]}
        elif [[ $line =~ ^[[:space:]]*-[[:space:]]*[\'\"]?(.+):(/[^:\'\"]+)(:ro|:rw)?[\'\"]?[[:space:]]*$ ]]; then s=${BASH_REMATCH[1]}; t=${BASH_REMATCH[2]}
        else continue; fi
        [ "$(norm "$(dirname "$s")")" = "$nb" ] || continue
        f=$(basename "$s"); [ -f "$run/$f" ] || die "override: $f mounted from base but not rendered"
        body+="$svc"$'\t'"$f"$'\t'"$t"$'\n'; n=$((n + 1))
    done < "$like"
    [ $n -gt 0 ] || die "override: no mount from $base in $like"
    { echo "# generated by ops/testrun/run-config.sh override; RUNCFG $(awk '$2=="RUNCFG"{print $1}' "$run/RUNCFG.sha256")"
      echo "services:"
      printf "%s" "$body" | sort -s -t $'	' -k1,1 | awk -F'\t' -v src="$src" '
          $1 != last { print "  " $1 ":"; print "    volumes:"; last = $1 }
          { printf "      - { type: bind, source: \"%s/%s\", target: %s, read_only: true }\n", src, $2, $3 }'
    } > "$out"
    echo "OVERRIDE $out mounts=$n"
}

case ${1:-} in
    render) shift; cmd_render "$@";;
    diff) shift; cmd_diff "$@";;
    verify) shift; cmd_verify "$@";;
    override) shift; cmd_override "$@";;
    hash) shift; [ -d "${1:-}" ] || die "hash: folder needed"; t=$(mktemp -d); cp -p "$1"/*.conf "$1"/*.tsv "$t"/ 2>/dev/null || true; rm -f "$t/keys.tsv"; hash_dir "$t"; rm -rf "$t";;
    *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2;;
esac
