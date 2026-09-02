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
for file in "$PROVENANCE" "$OUT/mangosd.conf" "$OUT/realmd.conf" "$OUT/aiplayerbot.conf"; do
    [[ -f "$file" && ! -L "$file" ]] || { echo "ERROR: generated configuration set is missing or unsafe" >&2; exit 1; }
    if [[ "$POSIX_MODE_ENFORCEMENT" == YES ]]; then
        mode=$(stat -c '%a' "$file")
        (( (8#$mode & 077) == 0 )) || { echo "ERROR: generated configuration permissions are too broad" >&2; exit 1; }
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
require_bytes AIPLAYERBOT_TEMPLATE_BYTES "$ROOT/modules/mod-playerbots/src/playerbot/aiplayerbot.conf.dist.in"
require_hash AIPLAYERBOT_TEMPLATE_SHA256 "$ROOT/modules/mod-playerbots/src/playerbot/aiplayerbot.conf.dist.in"
require_bytes AIPLAYERBOT_OVERLAY_BYTES "$CANONICAL/aiplayerbot.overlay.conf"
require_hash AIPLAYERBOT_OVERLAY_SHA256 "$CANONICAL/aiplayerbot.overlay.conf"
require_bytes AIPLAYERBOT_RENDERED_BYTES "$OUT/aiplayerbot.conf"
require_hash AIPLAYERBOT_RENDERED_SHA256 "$OUT/aiplayerbot.conf"

echo "configuration provenance verified"
