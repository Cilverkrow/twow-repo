#!/usr/bin/env bash
# Render complete Compose configuration from tracked templates plus the reviewed
# non-secret overlay. Runtime files are generated artifacts and are replaced on
# every render; their identity is recorded without exposing credentials.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CANONICAL="$ROOT/config/canonical/compose"
OUT="${CONFIG_OUT_DIR:-$HERE/config}"

MANGOSD_TEMPLATE="$ROOT/core/src/mangosd/mangosd.conf.dist.in"
REALMD_TEMPLATE="$ROOT/core/src/realmd/realmd.conf.dist.in"
AIPLAYERBOT_TEMPLATE="$ROOT/modules/mod-playerbots/src/playerbot/aiplayerbot.conf.dist.in"
MANGOSD_OVERLAY="$CANONICAL/mangosd.overlay.conf"
REALMD_OVERLAY="$CANONICAL/realmd.overlay.conf"
AIPLAYERBOT_OVERLAY="$CANONICAL/aiplayerbot.overlay.conf"
SEMANTIC_MATRIX="$CANONICAL/semantic-baseline.tsv"
VERIFIER="$HERE/verify-config.sh"

: "${DB_USER:?DB_USER not set -- source deploy/compose/.env first}"
: "${DB_PASSWORD:?DB_PASSWORD not set -- source deploy/compose/.env first}"
WORLD_PORT=${WORLD_PORT:-8090}
REALM_PORT=${REALM_PORT:-3724}
AIPLAYERBOT_MIN_BOTS=${AIPLAYERBOT_MIN_BOTS:-10}
AIPLAYERBOT_MAX_BOTS=${AIPLAYERBOT_MAX_BOTS:-10}
AIPLAYERBOT_LLM_API_KEY=${AIPLAYERBOT_LLM_API_KEY:-}

for tool in git sha256sum awk sed stat mktemp sort uniq grep; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool" >&2; exit 1; }
done

require_integer() {
    local name=$1 value=$2
    [[ "$value" =~ ^[0-9]+$ ]] || { echo "ERROR: $name must be an integer" >&2; exit 1; }
}
require_port() {
    local name=$1 value=$2
    require_integer "$name" "$value"
    (( value >= 1 && value <= 65535 )) || { echo "ERROR: $name is outside the valid port range" >&2; exit 1; }
}
reject_reserved_value() {
    local name=$1 value=$2
    case "$value" in
        *';'*|*'"'*|*\\*|*$'\r'*|*$'\n'*)
            echo "ERROR: $name contains a reserved configuration character" >&2
            exit 1
            ;;
    esac
}

require_port WORLD_PORT "$WORLD_PORT"
require_port REALM_PORT "$REALM_PORT"
require_integer AIPLAYERBOT_MIN_BOTS "$AIPLAYERBOT_MIN_BOTS"
require_integer AIPLAYERBOT_MAX_BOTS "$AIPLAYERBOT_MAX_BOTS"
(( AIPLAYERBOT_MIN_BOTS <= AIPLAYERBOT_MAX_BOTS )) || {
    echo "ERROR: AIPLAYERBOT_MIN_BOTS must not exceed AIPLAYERBOT_MAX_BOTS" >&2
    exit 1
}
reject_reserved_value DB_USER "$DB_USER"
reject_reserved_value DB_PASSWORD "$DB_PASSWORD"
reject_reserved_value AIPLAYERBOT_LLM_API_KEY "$AIPLAYERBOT_LLM_API_KEY"

for file in \
    "$MANGOSD_TEMPLATE" "$REALMD_TEMPLATE" "$AIPLAYERBOT_TEMPLATE" \
    "$MANGOSD_OVERLAY" "$REALMD_OVERLAY" "$AIPLAYERBOT_OVERLAY" \
    "$SEMANTIC_MATRIX" "$VERIFIER"; do
    [[ -f "$file" && ! -L "$file" ]] || { echo "ERROR: required tracked configuration input is missing or unsafe: $file" >&2; exit 1; }
done

SOURCE_COMMIT=$(git -C "$ROOT" rev-parse --verify HEAD)
SOURCE_TREE=$(git -C "$ROOT" rev-parse --verify 'HEAD^{tree}')
if test -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)"; then
    SOURCE_DIRTY=YES
else
    SOURCE_DIRTY=NO
fi
if [[ "$SOURCE_DIRTY" == YES && "${ALLOW_DIRTY_CONFIG_SOURCE:-0}" != 1 ]]; then
    # Say WHICH paths, or this is undiagnosable. It failed once in CI with no
    # indication of what was dirty, on a checkout that should have been pristine.
    echo "ERROR: refusing to render configuration from a dirty source checkout" >&2
    echo "dirty paths (git status --porcelain --untracked-files=all):" >&2
    git -C "$ROOT" status --porcelain --untracked-files=all >&2
    exit 1
fi

validate_overlay_keys() {
    local overlay=$1 duplicates
    duplicates=$(awk -F= '
        /^[[:space:]]*($|#|;)/ { next }
        NF < 2 { exit 3 }
        {
            key=$1
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (key == "") exit 3
            print key
        }
    ' "$overlay" | sort | uniq -d)
    [[ -z "$duplicates" ]] || { echo "ERROR: duplicate key in canonical overlay" >&2; exit 1; }

}

list_keys() {
    awk -F= '
        /^[[:space:]]*($|#|;)/ { next }
        NF < 2 { exit 3 }
        {
            key=$1
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (key == "") exit 3
            print key
        }
    ' "$1"
}

list_config_keys() {
    awk -F= '
        /^[[:space:]]*($|#|;)/ { next }
        NF >= 2 {
            key=$1
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (key != "") print key
        }
    ' "$1"
}

require_template_key() {
    local template=$1 key=$2 count
    count=$(awk -F= -v wanted="$key" '
        /^[[:space:]]*($|#|;)/ { next }
        {
            candidate=$1
            sub(/^[[:space:]]+/, "", candidate)
            sub(/[[:space:]]+$/, "", candidate)
            if (candidate == wanted) found++
        }
        END { print found + 0 }
    ' "$template")
    [[ "$count" == 1 ]] || { echo "ERROR: required connection key is not unique in its complete base template" >&2; exit 1; }
}

validate_overlay_keys "$MANGOSD_OVERLAY"
validate_overlay_keys "$REALMD_OVERLAY"
validate_overlay_keys "$AIPLAYERBOT_OVERLAY"
require_template_key "$MANGOSD_TEMPLATE" LoginDatabase.Info
require_template_key "$MANGOSD_TEMPLATE" WorldDatabase.Info
require_template_key "$MANGOSD_TEMPLATE" CharacterDatabase.Info
require_template_key "$MANGOSD_TEMPLATE" LogsDatabase.Info
require_template_key "$REALMD_TEMPLATE" LoginDatabaseInfo

mkdir -p "$OUT"
umask 077
STAGE=$(mktemp -d "$OUT/.config-stage.XXXXXX")
cleanup() { rm -rf -- "$STAGE"; }
trap cleanup EXIT

apply_overlay() {
    local template=$1 overlay=$2 destination=$3
    awk '
        function active_key(line, pos, key) {
            if (line ~ /^[[:space:]]*($|#|;)/) return ""
            pos=index(line, "=")
            if (!pos) return ""
            key=substr(line, 1, pos - 1)
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            return key
        }
        FNR == NR {
            key=active_key($0)
            if (key == "") next
            if (key in replacement) { failed=1; exit }
            replacement[key]=$0
            order[++count]=key
            next
        }
        {
            key=active_key($0)
            if (key != "" && key in replacement) {
                seen[key]++
                if (seen[key] == 1) print replacement[key]
            } else {
                print
            }
        }
        END {
            if (failed) exit 9
            print ""
            print "########################################################################"
            print "# Canonical generated values absent from the complete base template."
            print "# Direct edits are drift and are replaced by the next verified render."
            print "########################################################################"
            for (i=1; i<=count; i++) {
                key=order[i]
                if (!seen[key]) print replacement[key]
            }
        }
    ' "$overlay" "$template" > "$destination" || {
        echo "ERROR: could not apply canonical overlay uniquely" >&2
        exit 1
    }
}

sed \
    -e "s|@AIPLAYERBOT_MIN_BOTS@|$AIPLAYERBOT_MIN_BOTS|g" \
    -e "s|@AIPLAYERBOT_MAX_BOTS@|$AIPLAYERBOT_MAX_BOTS|g" \
    "$AIPLAYERBOT_OVERLAY" > "$STAGE/aiplayerbot.overlay.conf"

apply_overlay "$MANGOSD_TEMPLATE" "$MANGOSD_OVERLAY" "$STAGE/mangosd.nonsecret.conf"
apply_overlay "$REALMD_TEMPLATE" "$REALMD_OVERLAY" "$STAGE/realmd.nonsecret.conf"
apply_overlay "$AIPLAYERBOT_TEMPLATE" "$STAGE/aiplayerbot.overlay.conf" "$STAGE/aiplayerbot.nonsecret.conf"

# The service parser has no external secret provider. These are the only secret
# machine-overlay values and are intentionally absent from provenance output.
connection() { printf 'db;3306;%s;%s;%s' "$DB_USER" "$DB_PASSWORD" "$1"; }
{
    printf 'LoginDatabase.Info = "%s"\n' "$(connection tw_logon)"
    printf 'WorldDatabase.Info = "%s"\n' "$(connection tw_world)"
    printf 'CharacterDatabase.Info = "%s"\n' "$(connection tw_char)"
    printf 'LogsDatabase.Info = "%s"\n' "$(connection tw_logs)"
} > "$STAGE/mangosd.machine.conf"
{
    printf 'LoginDatabaseInfo = "%s"\n' "$(connection tw_logon)"
} > "$STAGE/realmd.machine.conf"
printf 'AiPlayerbot.LLMApiKey = %s\n' "$AIPLAYERBOT_LLM_API_KEY" > "$STAGE/aiplayerbot.machine.conf"

apply_overlay "$STAGE/mangosd.nonsecret.conf" "$STAGE/mangosd.machine.conf" "$STAGE/mangosd.conf"
apply_overlay "$STAGE/realmd.nonsecret.conf" "$STAGE/realmd.machine.conf" "$STAGE/realmd.conf"
apply_overlay "$STAGE/aiplayerbot.nonsecret.conf" "$STAGE/aiplayerbot.machine.conf" "$STAGE/aiplayerbot.conf"

key_count() {
    local config=$1 wanted=$2
    awk -F= -v wanted="$wanted" '
        /^[[:space:]]*($|#|;)/ { next }
        {
            key=$1
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (key == wanted) found++
        }
        END { print found + 0 }
    ' "$config"
}
assert_keys_once() {
    local config=$1 key_file=$2
    list_keys "$key_file" | while IFS= read -r key; do
        [[ "$(key_count "$config" "$key")" == 1 ]] || {
            echo "ERROR: generated canonical key is not unique" >&2
            exit 1
        }
    done
}
assert_no_duplicate_keys() {
    local config=$1 duplicates
    duplicates=$(list_config_keys "$config" | sort | uniq -d)
    [[ -z "$duplicates" ]] || {
        echo "ERROR: generated configuration contains a duplicate active key" >&2
        exit 1
    }
}
assert_keys_once "$STAGE/mangosd.conf" "$MANGOSD_OVERLAY"
assert_keys_once "$STAGE/mangosd.conf" "$STAGE/mangosd.machine.conf"
assert_keys_once "$STAGE/realmd.conf" "$REALMD_OVERLAY"
assert_keys_once "$STAGE/realmd.conf" "$STAGE/realmd.machine.conf"
assert_keys_once "$STAGE/aiplayerbot.conf" "$STAGE/aiplayerbot.overlay.conf"
assert_keys_once "$STAGE/aiplayerbot.conf" "$STAGE/aiplayerbot.machine.conf"
for config in "$STAGE/mangosd.conf" "$STAGE/realmd.conf" "$STAGE/aiplayerbot.conf"; do
    assert_no_duplicate_keys "$config"
    if grep -Eq '@[A-Z0-9_]+@' "$config"; then
        echo "ERROR: unresolved canonical configuration token" >&2
        exit 1
    fi
done

chmod 600 "$STAGE/mangosd.conf" "$STAGE/realmd.conf" "$STAGE/aiplayerbot.conf"
hash_file() { sha256sum "$1" | awk '{print $1}'; }
file_bytes() { stat -c '%s' "$1"; }

cat > "$STAGE/config-provenance.txt" <<EOF
FORMAT_VERSION=2
TASK_ID=OPS-009-R1-SEMANTIC-BASELINE-RECONCILIATION-01
DECISION=ADR-0038
SOURCE_COMMIT=$SOURCE_COMMIT
SOURCE_TREE=$SOURCE_TREE
SOURCE_DIRTY=$SOURCE_DIRTY
RENDERED_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
RENDERER_SHA256=$(hash_file "$HERE/render-config.sh")
VERIFIER_SHA256=$(hash_file "$VERIFIER")
SEMANTIC_MATRIX_BYTES=$(file_bytes "$SEMANTIC_MATRIX")
SEMANTIC_MATRIX_SHA256=$(hash_file "$SEMANTIC_MATRIX")
MANGOSD_TEMPLATE_BYTES=$(file_bytes "$MANGOSD_TEMPLATE")
MANGOSD_TEMPLATE_SHA256=$(hash_file "$MANGOSD_TEMPLATE")
MANGOSD_OVERLAY_BYTES=$(file_bytes "$MANGOSD_OVERLAY")
MANGOSD_OVERLAY_SHA256=$(hash_file "$MANGOSD_OVERLAY")
MANGOSD_RENDERED_BYTES=$(file_bytes "$STAGE/mangosd.conf")
MANGOSD_RENDERED_SHA256=$(hash_file "$STAGE/mangosd.conf")
REALMD_TEMPLATE_BYTES=$(file_bytes "$REALMD_TEMPLATE")
REALMD_TEMPLATE_SHA256=$(hash_file "$REALMD_TEMPLATE")
REALMD_OVERLAY_BYTES=$(file_bytes "$REALMD_OVERLAY")
REALMD_OVERLAY_SHA256=$(hash_file "$REALMD_OVERLAY")
REALMD_RENDERED_BYTES=$(file_bytes "$STAGE/realmd.conf")
REALMD_RENDERED_SHA256=$(hash_file "$STAGE/realmd.conf")
AIPLAYERBOT_TEMPLATE_BYTES=$(file_bytes "$AIPLAYERBOT_TEMPLATE")
AIPLAYERBOT_TEMPLATE_SHA256=$(hash_file "$AIPLAYERBOT_TEMPLATE")
AIPLAYERBOT_OVERLAY_BYTES=$(file_bytes "$AIPLAYERBOT_OVERLAY")
AIPLAYERBOT_OVERLAY_SHA256=$(hash_file "$AIPLAYERBOT_OVERLAY")
AIPLAYERBOT_RENDERED_BYTES=$(file_bytes "$STAGE/aiplayerbot.conf")
AIPLAYERBOT_RENDERED_SHA256=$(hash_file "$STAGE/aiplayerbot.conf")
EOF
chmod 600 "$STAGE/config-provenance.txt"

# Files publish one by one; provenance publishes last. Any interrupted or mixed
# set therefore fails verification before `make up` can consume it.
for name in mangosd.conf realmd.conf aiplayerbot.conf config-provenance.txt; do
    mv -f -- "$STAGE/$name" "$OUT/$name"
done

# ------------------------------------------------------------- permissions
#
# Every file rendered above carries the database password in cleartext, and
# every one of them is bind-mounted into a container that runs as the
# unprivileged `turtle` account -- uid 10001, pinned in
# deploy/docker/Dockerfile.core, see the long comment there.
#
# Those two facts used to contradict each other. The files were mode 600 owned
# by whoever ran this script (uid 1000 on a developer box, 1001 on the GitHub
# runner), the container process was a different uid entirely, and so realmd
# could not read /opt/turtle/etc/realmd.conf. Mangos reports an unreadable
# config as "Could not find configuration file", which sends you hunting for a
# missing bind mount instead of a permission bit; the stack had in fact never
# come up under compose. This applies to all three files, not just realmd's:
# mangosd.conf and aiplayerbot.conf are mounted the same way.
#
# The directory is the real guard. 0700 means no other account on this host can
# reach these files at all, whatever mode the files themselves carry, and the
# container never traverses it -- a bind mount resolves the file's inode, so the
# only path check inside the container is against image-owned /opt/turtle/etc.
chmod 700 "$OUT"
chmod 600 "$OUT"/*.conf

# Preferred: keep 0600 and hand uid 10001 an explicit read entry. A file's owner
# may grant an ACL to any uid without being root, which is the only mechanism
# here that works unprivileged in both environments that matter -- the CI runner
# renders these as uid 1001 with no sudo in that step, and a developer renders
# them as their own login uid. Neither can chown to 10001, and neither is in a
# group the container user belongs to, so plain owner/group bits cannot express
# "readable by exactly one foreign uid" and an ACL can.
#
# Fallback: filesystems mounted without ACL support and hosts with no setfacl
# (a Docker Desktop file share, a busybox environment) cannot do that, and a
# stack that will not start is worse than a mode bit. 0644 there is not a
# meaningful loss: the 0700 directory above still keeps every account except
# root and the owner out, and root can read the file whatever its mode says.
if setfacl -m "u:10001:r" "$OUT"/*.conf 2>/dev/null; then
    echo "granted uid 10001 (container 'turtle') read access via ACL" >&2
else
    chmod 644 "$OUT"/*.conf
    echo "no usable ACL support here; configs are 0644 inside a 0700 $OUT" >&2
fi

echo "configuration rendered with provenance"
