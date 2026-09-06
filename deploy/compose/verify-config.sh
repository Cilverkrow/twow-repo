#!/usr/bin/env bash
# Verify generated configuration without printing any rendered content or
# credentials. This detects both runtime drift and source/provenance drift.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CANONICAL="$ROOT/config/canonical/compose"
OUT="${CONFIG_OUT_DIR:-$HERE/config}"
PROVENANCE="$OUT/config-provenance.txt"

hash_file() { sha256sum "$1" | awk '{print $1}'; }
manifest_value() {
    local key=$1
    awk -F= -v wanted="$key" '
        $1 == wanted { sub(/^[^=]*=/, ""); print; found++ }
        END { if (found != 1) exit 2 }
    ' "$PROVENANCE"
}
require_hash() {
    local field=$1 path=$2 expected actual
    expected=$(manifest_value "$field") || { echo "ERROR: malformed provenance field: $field" >&2; exit 1; }
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo "ERROR: invalid provenance hash: $field" >&2; exit 1; }
    actual=$(hash_file "$path")
    [[ "$actual" == "$expected" ]] || { echo "ERROR: configuration provenance mismatch: $field" >&2; exit 1; }
}
require_bytes() {
    local field=$1 path=$2 expected actual
    expected=$(manifest_value "$field") || { echo "ERROR: malformed provenance field: $field" >&2; exit 1; }
    [[ "$expected" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid provenance byte count: $field" >&2; exit 1; }
    actual=$(stat -c '%s' "$path")
    [[ "$actual" == "$expected" ]] || { echo "ERROR: configuration provenance byte-count mismatch: $field" >&2; exit 1; }
}

for tool in git sha256sum awk stat uname; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool missing: $tool" >&2; exit 1; }
done
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) POSIX_MODE_ENFORCEMENT=NO ;;
    *) POSIX_MODE_ENFORCEMENT=YES ;;
esac
# The rendered files carry the database password in cleartext, so this gate
# exists to keep them away from other accounts on the host. What enforces that
# is the DIRECTORY, not the file bits, and the check has to be written that way
# or it rejects the renderer's own output.
#
# render-config.sh finishes in exactly one of two states (see the permissions
# section at the end of that file):
#
#   ACL path      chmod 600, then `setfacl -m u:10001:r`. A POSIX ACL puts its
#                 mask in the group bits, so `stat -c %a` reports 640 even
#                 though the real group entry is `group::---`.
#   fallback      chmod 644, on a host with no setfacl or a filesystem mounted
#                 without ACL support. The container runs as uid 10001 and the
#                 renderer runs unprivileged -- it can neither chown nor add a
#                 group -- so other-read is the only remaining way to grant
#                 that uid read access, and a stack that will not start is
#                 worse than a mode bit.
#
# The `(mode & 077) == 0` this replaces rejected BOTH of those, so `make up`
# stopped here with "permissions are too broad" whether or not `acl` was
# installed. `(mode & 007) == 0` is not the fix either: it accepts 640 and
# still rejects the 0644 fallback.
#
# So the confidentiality guarantee is asserted where it is actually enforced.
# $OUT must be 0700 -- that keeps every account except the owner and root out,
# whatever the files inside it say, and it is a NEW assertion: nothing checked
# the directory before. The per-file check then keeps the part that still means
# something inside a 0700 directory: no group- or world-WRITE, so nothing but
# the owner can alter a config the server is about to read.
if [[ "$POSIX_MODE_ENFORCEMENT" == YES ]]; then
    [[ -d "$OUT" && ! -L "$OUT" ]] || { echo "ERROR: generated configuration directory is missing or unsafe" >&2; exit 1; }
    dir_mode=$(stat -c '%a' "$OUT")
    (( 8#$dir_mode == 8#700 )) || { echo "ERROR: generated configuration directory is not 0700" >&2; exit 1; }
fi
for file in "$PROVENANCE" "$OUT/mangosd.conf" "$OUT/realmd.conf" "$OUT/aiplayerbot.conf"; do
    [[ -f "$file" && ! -L "$file" ]] || { echo "ERROR: generated configuration set is missing or unsafe" >&2; exit 1; }
    if [[ "$POSIX_MODE_ENFORCEMENT" == YES ]]; then
        mode=$(stat -c '%a' "$file")
        (( (8#$mode & 022) == 0 )) || { echo "ERROR: generated configuration is writable by group or other" >&2; exit 1; }
    fi
done

[[ "$(manifest_value FORMAT_VERSION)" == 2 ]] || { echo "ERROR: unsupported provenance format" >&2; exit 1; }
[[ "$(manifest_value TASK_ID)" == OPS-009-R1-SEMANTIC-BASELINE-RECONCILIATION-01 ]] || { echo "ERROR: provenance task mismatch" >&2; exit 1; }
[[ "$(manifest_value DECISION)" == ADR-0038 ]] || { echo "ERROR: provenance decision mismatch" >&2; exit 1; }

current_commit=$(git -C "$ROOT" rev-parse --verify HEAD)
current_tree=$(git -C "$ROOT" rev-parse --verify 'HEAD^{tree}')
[[ "$current_commit" == "$(manifest_value SOURCE_COMMIT)" ]] || { echo "ERROR: source commit changed after rendering" >&2; exit 1; }
[[ "$current_tree" == "$(manifest_value SOURCE_TREE)" ]] || { echo "ERROR: source tree changed after rendering" >&2; exit 1; }
if test -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)"; then current_dirty=YES; else current_dirty=NO; fi
recorded_dirty=$(manifest_value SOURCE_DIRTY)
[[ "$recorded_dirty" == "$current_dirty" ]] || { echo "ERROR: source dirty state changed after rendering" >&2; exit 1; }
if [[ "$recorded_dirty" == YES && "${ALLOW_DIRTY_CONFIG_SOURCE:-0}" != 1 ]]; then
    echo "ERROR: provenance records a dirty source checkout" >&2
    exit 1
fi

require_hash RENDERER_SHA256 "$HERE/render-config.sh"
require_hash VERIFIER_SHA256 "$HERE/verify-config.sh"
require_bytes SEMANTIC_MATRIX_BYTES "$CANONICAL/semantic-baseline.tsv"
require_hash SEMANTIC_MATRIX_SHA256 "$CANONICAL/semantic-baseline.tsv"
require_bytes MANGOSD_TEMPLATE_BYTES "$ROOT/core/src/mangosd/mangosd.conf.dist.in"
require_hash MANGOSD_TEMPLATE_SHA256 "$ROOT/core/src/mangosd/mangosd.conf.dist.in"
require_bytes MANGOSD_OVERLAY_BYTES "$CANONICAL/mangosd.overlay.conf"
require_hash MANGOSD_OVERLAY_SHA256 "$CANONICAL/mangosd.overlay.conf"
require_bytes MANGOSD_RENDERED_BYTES "$OUT/mangosd.conf"
require_hash MANGOSD_RENDERED_SHA256 "$OUT/mangosd.conf"
require_bytes REALMD_TEMPLATE_BYTES "$ROOT/core/src/realmd/realmd.conf.dist.in"
require_hash REALMD_TEMPLATE_SHA256 "$ROOT/core/src/realmd/realmd.conf.dist.in"
require_bytes REALMD_OVERLAY_BYTES "$CANONICAL/realmd.overlay.conf"
require_hash REALMD_OVERLAY_SHA256 "$CANONICAL/realmd.overlay.conf"
require_bytes REALMD_RENDERED_BYTES "$OUT/realmd.conf"
require_hash REALMD_RENDERED_SHA256 "$OUT/realmd.conf"
require_bytes AIPLAYERBOT_TEMPLATE_BYTES "$ROOT/core/modules/mod-playerbots/src/playerbot/aiplayerbot.conf.dist.in"
require_hash AIPLAYERBOT_TEMPLATE_SHA256 "$ROOT/core/modules/mod-playerbots/src/playerbot/aiplayerbot.conf.dist.in"
require_bytes AIPLAYERBOT_OVERLAY_BYTES "$CANONICAL/aiplayerbot.overlay.conf"
require_hash AIPLAYERBOT_OVERLAY_SHA256 "$CANONICAL/aiplayerbot.overlay.conf"
require_bytes AIPLAYERBOT_RENDERED_BYTES "$OUT/aiplayerbot.conf"
require_hash AIPLAYERBOT_RENDERED_SHA256 "$OUT/aiplayerbot.conf"

echo "configuration provenance verified"
