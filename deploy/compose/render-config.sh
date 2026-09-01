#!/usr/bin/env bash
# Render complete Compose configuration from tracked templates plus the reviewed
# non-secret overlay. Runtime files are generated artifacts and are replaced on
# every render; their identity is recorded without exposing credentials.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CANONICAL="$ROOT/config/canonical/compose"
OUT="${CONFIG_OUT_DIR:-$HERE/config}"

MANGOSD_TEMPLATE="$ROOT/src/mangosd/mangosd.conf.dist.in"
REALMD_TEMPLATE="$ROOT/src/realmd/realmd.conf.dist.in"
AIPLAYERBOT_TEMPLATE="$ROOT/modules/mod-playerbots/src/playerbot/aiplayerbot.conf.dist.in"
MANGOSD_OVERLAY="$CANONICAL/mangosd.overlay.conf"
REALMD_OVERLAY="$CANONICAL/realmd.overlay.conf"
AIPLAYERBOT_OVERLAY="$CANONICAL/aiplayerbot.overlay.conf"
VERIFIER="$HERE/verify-config.sh"

: "${DB_USER:?DB_USER not set -- source deploy/compose/.env first}"
: "${DB_PASSWORD:?DB_PASSWORD not set -- source deploy/compose/.env first}"
WORLD_PORT=${WORLD_PORT:-8090}
REALM_PORT=${REALM_PORT:-3724}
AIPLAYERBOT_MIN_BOTS=${AIPLAYERBOT_MIN_BOTS:-10}
AIPLAYERBOT_MAX_BOTS=${AIPLAYERBOT_MAX_BOTS:-10}

for tool in git sha256sum awk sed stat mktemp; do
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

for file in \
    "$MANGOSD_TEMPLATE" "$REALMD_TEMPLATE" "$AIPLAYERBOT_TEMPLATE" \
    "$MANGOSD_OVERLAY" "$REALMD_OVERLAY" "$AIPLAYERBOT_OVERLAY" "$VERIFIER"; do
    [[ -f "$file" && ! -L "$file" ]] || { echo "ERROR: required tracked configuration input is missing or unsafe" >&2; exit 1; }
done

SOURCE_COMMIT=$(git -C "$ROOT" rev-parse --verify HEAD)
SOURCE_TREE=$(git -C "$ROOT" rev-parse --verify 'HEAD^{tree}')
if test -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)"; then
    SOURCE_DIRTY=YES
else
    SOURCE_DIRTY=NO
fi
if [[ "$SOURCE_DIRTY" == YES && "${ALLOW_DIRTY_CONFIG_SOURCE:-0}" != 1 ]]; then
    echo "ERROR: refusing to render configuration from a dirty source checkout" >&2
    exit 1
fi

validate_overlay_keys() {
    local template=$1 overlay=$2
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
    ' "$overlay" | while IFS= read -r key; do
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
        [[ "$count" == 1 ]] || { echo "ERROR: canonical overlay key is not unique in its complete base template" >&2; exit 1; }
    done
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

validate_overlay_keys "$MANGOSD_TEMPLATE" "$MANGOSD_OVERLAY"
validate_overlay_keys "$REALMD_TEMPLATE" "$REALMD_OVERLAY"
validate_overlay_keys "$AIPLAYERBOT_TEMPLATE" "$AIPLAYERBOT_OVERLAY"
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

render_overlay() {
    local template=$1 overlay=$2 destination=$3
    cp -- "$template" "$destination"
    {
        printf '\n########################################################################\n'
        printf '# Canonical Compose overlay; generated by deploy/compose/render-config.sh\n'
        printf '# Direct edits are drift and will be replaced by the next render.\n'
        printf '########################################################################\n'
        sed \
            -e "s|@AIPLAYERBOT_MIN_BOTS@|$AIPLAYERBOT_MIN_BOTS|g" \
            -e "s|@AIPLAYERBOT_MAX_BOTS@|$AIPLAYERBOT_MAX_BOTS|g" \
            "$overlay"
    } >> "$destination"
    if grep -Eq '@[A-Z0-9_]+@' "$destination"; then
        echo "ERROR: unresolved canonical configuration token" >&2
        exit 1
    fi
}

render_overlay "$MANGOSD_TEMPLATE" "$MANGOSD_OVERLAY" "$STAGE/mangosd.conf"
render_overlay "$REALMD_TEMPLATE" "$REALMD_OVERLAY" "$STAGE/realmd.conf"
render_overlay "$AIPLAYERBOT_TEMPLATE" "$AIPLAYERBOT_OVERLAY" "$STAGE/aiplayerbot.conf"

# The service parser has no external secret provider. These are the only secret
# machine-overlay values and are intentionally absent from provenance output.
connection() { printf 'db;3306;%s;%s;%s' "$DB_USER" "$DB_PASSWORD" "$1"; }
{
    printf '\n# Protected machine overlay (generated; never commit)\n'
    printf 'LoginDatabase.Info = "%s"\n' "$(connection tw_logon)"
    printf 'WorldDatabase.Info = "%s"\n' "$(connection tw_world)"
    printf 'CharacterDatabase.Info = "%s"\n' "$(connection tw_char)"
    printf 'LogsDatabase.Info = "%s"\n' "$(connection tw_logs)"
} >> "$STAGE/mangosd.conf"
{
    printf '\n# Protected machine overlay (generated; never commit)\n'
    printf 'LoginDatabaseInfo = "%s"\n' "$(connection tw_logon)"
} >> "$STAGE/realmd.conf"

chmod 600 "$STAGE/mangosd.conf" "$STAGE/realmd.conf" "$STAGE/aiplayerbot.conf"
hash_file() { sha256sum "$1" | awk '{print $1}'; }
file_bytes() { stat -c '%s' "$1"; }

cat > "$STAGE/config-provenance.txt" <<EOF
FORMAT_VERSION=1
TASK_ID=OPS-009-CONFIG-AS-CODE-IMPLEMENTATION-01
DECISION=ADR-0038
SOURCE_COMMIT=$SOURCE_COMMIT
SOURCE_TREE=$SOURCE_TREE
SOURCE_DIRTY=$SOURCE_DIRTY
RENDERED_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
RENDERER_SHA256=$(hash_file "$HERE/render-config.sh")
VERIFIER_SHA256=$(hash_file "$VERIFIER")
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
