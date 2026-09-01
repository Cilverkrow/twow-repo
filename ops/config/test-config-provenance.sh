#!/usr/bin/env bash
# Repository-only semantic/provenance test. It uses synthetic credentials in a
# temporary directory and never contacts a process, service, or database.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CANONICAL="$ROOT/config/canonical/compose"
MATRIX="$CANONICAL/semantic-baseline.tsv"
TMP=$(mktemp -d)
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

export CONFIG_OUT_DIR="$TMP/config"
export DB_USER="synthetic-""user"
export DB_PASSWORD="synthetic-""password"
export AIPLAYERBOT_LLM_API_KEY="synthetic-""api-key"
export WORLD_PORT=18090
export REALM_PORT=13724
export AIPLAYERBOT_MIN_BOTS=3
export AIPLAYERBOT_MAX_BOTS=7

if test -n "$(git -C "$ROOT" status --porcelain --untracked-files=all)"; then
    unset ALLOW_DIRTY_CONFIG_SOURCE
    if bash "$ROOT/deploy/compose/render-config.sh" >/dev/null 2>&1; then
        echo "ERROR: renderer accepted a dirty source checkout by default" >&2
        exit 1
    fi
    export ALLOW_DIRTY_CONFIG_SOURCE=1
fi

key_count() {
    local file=$1 wanted=$2
    awk -F= -v wanted="$wanted" '
        /^[[:space:]]*($|#|;)/ { next }
        {
            key=$1
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            if (key == wanted) found++
        }
        END { print found + 0 }
    ' "$file"
}

key_value() {
    local file=$1 wanted=$2
    awk -v wanted="$wanted" '
        function active_key(line, pos, key) {
            if (line ~ /^[[:space:]]*($|#|;)/) return ""
            pos=index(line, "=")
            if (!pos) return ""
            key=substr(line, 1, pos - 1)
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            return key
        }
        active_key($0) == wanted {
            value=substr($0, index($0, "=") + 1)
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            found=1
        }
        END { if (found) print value }
    ' "$file"
}

list_keys() {
    awk -F= '
        /^[[:space:]]*($|#|;)/ { next }
        NF >= 2 {
            key=$1
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            print key
        }
    ' "$1"
}

assert_key_once() {
    local file=$1 key=$2
    [[ "$(key_count "$file" "$key")" == 1 ]] || {
        echo "ERROR: expected canonical key is not unique" >&2
        exit 1
    }
}

assert_overlay_keys_once() {
    local overlay=$1 rendered=$2
    list_keys "$overlay" | while IFS= read -r key; do
        assert_key_once "$rendered" "$key"
    done
}

assert_no_duplicate_keys() {
    local rendered=$1 duplicates
    duplicates=$(list_keys "$rendered" | sort | uniq -d)
    [[ -z "$duplicates" ]] || {
        echo "ERROR: rendered configuration contains a duplicate active key" >&2
        exit 1
    }
}

assert_matrix() {
    awk -F '\t' '
        /^#/ { next }
        $1 == "service" { next }
        NF != 5 { exit 10 }
        {
            identity=$1 SUBSEP $2
            if (seen[identity]++) exit 11
            if ($3 != "KEEP" && $3 != "INTENTIONAL_CHANGE" &&
                $3 != "DEPRECATED_OR_REMOVED" && $3 != "MACHINE_SECRET") exit 12
            count[$3]++
            total++
        }
        END {
            if (total != 115 || count["KEEP"] != 95 ||
                count["INTENTIONAL_CHANGE"] != 14 ||
                count["DEPRECATED_OR_REMOVED"] != 0 ||
                count["MACHINE_SECRET"] != 6) exit 13
        }
    ' "$MATRIX" || { echo "ERROR: semantic matrix is incomplete or malformed" >&2; exit 1; }
}

assert_semantics() {
    local service key classification canonical_source evidence rendered baseline
    local template overlay expected actual
    while IFS=$'\t' read -r service key classification canonical_source evidence; do
        [[ "$service" == service || "$service" == \#* || -z "$service" ]] && continue
        case "$service" in
            mangosd)
                rendered="$CONFIG_OUT_DIR/mangosd.conf"
                baseline="$ROOT/config/examples/mangosd.local.example.conf"
                template="$ROOT/src/mangosd/mangosd.conf.dist.in"
                overlay="$CANONICAL/mangosd.overlay.conf"
                ;;
            realmd)
                rendered="$CONFIG_OUT_DIR/realmd.conf"
                baseline="$ROOT/config/examples/realmd.local.example.conf"
                template="$ROOT/src/realmd/realmd.conf.dist.in"
                overlay="$CANONICAL/realmd.overlay.conf"
                ;;
            aiplayerbot)
                rendered="$CONFIG_OUT_DIR/aiplayerbot.conf"
                baseline="$ROOT/config/examples/aiplayerbot.local.example.conf"
                template="$ROOT/modules/mod-playerbots/src/playerbot/aiplayerbot.conf.dist.in"
                overlay="$CANONICAL/aiplayerbot.overlay.conf"
                ;;
            *) echo "ERROR: unknown semantic-matrix service" >&2; exit 1 ;;
        esac

        if [[ "$classification" == DEPRECATED_OR_REMOVED ]]; then
            [[ "$(key_count "$rendered" "$key")" == 0 ]] || {
                echo "ERROR: removed semantic key was rendered" >&2
                exit 1
            }
            continue
        fi
        assert_key_once "$rendered" "$key"
        if [[ "$classification" == KEEP ]]; then
            [[ "$(key_value "$rendered" "$key")" == "$(key_value "$baseline" "$key")" ]] || {
                echo "ERROR: KEEP semantic value changed: $key" >&2
                exit 1
            }
        elif [[ "$classification" == INTENTIONAL_CHANGE ]]; then
            actual=$(key_value "$rendered" "$key")
            case "$key" in
                AiPlayerbot.MinRandomBots) expected=3 ;;
                AiPlayerbot.MaxRandomBots) expected=7 ;;
                *)
                    if [[ "$canonical_source" == complete-base-template ]]; then
                        expected=$(key_value "$template" "$key")
                    else
                        [[ "$canonical_source" == "$(basename "$overlay")" ]] || {
                            echo "ERROR: intentional semantic source mismatch" >&2
                            exit 1
                        }
                        expected=$(key_value "$overlay" "$key")
                    fi
                    ;;
            esac
            [[ "$actual" == "$expected" ]] || {
                echo "ERROR: intentional semantic value changed: $key" >&2
                exit 1
            }
        fi
        [[ -n "$canonical_source" && -n "$evidence" ]]
    done < "$MATRIX"
}

assert_rendered_contract() {
    assert_matrix
    assert_no_duplicate_keys "$CONFIG_OUT_DIR/mangosd.conf"
    assert_no_duplicate_keys "$CONFIG_OUT_DIR/realmd.conf"
    assert_no_duplicate_keys "$CONFIG_OUT_DIR/aiplayerbot.conf"
    assert_overlay_keys_once "$CANONICAL/mangosd.overlay.conf" "$CONFIG_OUT_DIR/mangosd.conf"
    assert_overlay_keys_once "$CANONICAL/realmd.overlay.conf" "$CONFIG_OUT_DIR/realmd.conf"
    assert_overlay_keys_once "$CANONICAL/aiplayerbot.overlay.conf" "$CONFIG_OUT_DIR/aiplayerbot.conf"
    for key in LoginDatabase.Info WorldDatabase.Info CharacterDatabase.Info LogsDatabase.Info; do
        assert_key_once "$CONFIG_OUT_DIR/mangosd.conf" "$key"
    done
    assert_key_once "$CONFIG_OUT_DIR/realmd.conf" LoginDatabaseInfo
    assert_key_once "$CONFIG_OUT_DIR/aiplayerbot.conf" AiPlayerbot.LLMApiKey

    [[ "$(key_value "$CONFIG_OUT_DIR/aiplayerbot.conf" AiPlayerbot.MinRandomBots)" == 3 ]]
    [[ "$(key_value "$CONFIG_OUT_DIR/aiplayerbot.conf" AiPlayerbot.MaxRandomBots)" == 7 ]]
    for key in LFT.BotFill.Enable LFT.BotFill.DelaySeconds LFT.BotFill.LevelRangeBelow \
               LFT.BotFill.LevelRangeBelowHealer LFT.BotFill.LevelRangeAbove; do
        assert_key_once "$CONFIG_OUT_DIR/mangosd.conf" "$key"
    done
    grep -Fq 'LFT/LFTBotFill.cpp' "$ROOT/src/game/CMakeLists.txt"

    if grep -Eq '@[A-Z0-9_]+@' "$CONFIG_OUT_DIR"/*.conf; then
        echo "ERROR: unresolved configuration token" >&2
        exit 1
    fi
    assert_semantics
}

bash "$ROOT/deploy/compose/render-config.sh" >/dev/null
bash "$ROOT/deploy/compose/verify-config.sh" >/dev/null
assert_rendered_contract

grep -Fq "$DB_PASSWORD" "$CONFIG_OUT_DIR/mangosd.conf"
grep -Fq "$DB_PASSWORD" "$CONFIG_OUT_DIR/realmd.conf"
grep -Fq "$AIPLAYERBOT_LLM_API_KEY" "$CONFIG_OUT_DIR/aiplayerbot.conf"
for credential in "$DB_USER" "$DB_PASSWORD" "$AIPLAYERBOT_LLM_API_KEY"; do
    if git -C "$ROOT" grep -F -- "$credential" >/dev/null 2>&1; then
        echo "ERROR: synthetic credential is present in Git" >&2
        exit 1
    fi
    if grep -Fq "$credential" "$CONFIG_OUT_DIR/config-provenance.txt"; then
        echo "ERROR: provenance contains a credential" >&2
        exit 1
    fi
done

# Same inputs produce byte-identical configs and provenance after removing the
# documented render timestamp.
mkdir -p "$TMP/first"
cp -- "$CONFIG_OUT_DIR"/*.conf "$TMP/first/"
grep -v '^RENDERED_UTC=' "$CONFIG_OUT_DIR/config-provenance.txt" > "$TMP/first/provenance.normalized"
bash "$ROOT/deploy/compose/render-config.sh" >/dev/null
bash "$ROOT/deploy/compose/verify-config.sh" >/dev/null
for name in mangosd.conf realmd.conf aiplayerbot.conf; do
    cmp -s "$TMP/first/$name" "$CONFIG_OUT_DIR/$name" || {
        echo "ERROR: repeated render changed canonical output" >&2
        exit 1
    }
done
grep -v '^RENDERED_UTC=' "$CONFIG_OUT_DIR/config-provenance.txt" > "$TMP/provenance.normalized"
cmp -s "$TMP/first/provenance.normalized" "$TMP/provenance.normalized" || {
    echo "ERROR: repeated render changed normalized provenance" >&2
    exit 1
}

# Deliberate content drift is rejected.
printf '\n# deliberate test drift\n' >> "$CONFIG_OUT_DIR/mangosd.conf"
if bash "$ROOT/deploy/compose/verify-config.sh" >/dev/null 2>&1; then
    echo "ERROR: verifier accepted a changed rendered file" >&2
    exit 1
fi
bash "$ROOT/deploy/compose/render-config.sh" >/dev/null

# An incomplete set is rejected.
mv -- "$CONFIG_OUT_DIR/realmd.conf" "$TMP/realmd.missing"
if bash "$ROOT/deploy/compose/verify-config.sh" >/dev/null 2>&1; then
    echo "ERROR: verifier accepted an incomplete generation" >&2
    exit 1
fi
bash "$ROOT/deploy/compose/render-config.sh" >/dev/null

# A file from one valid generation mixed with another valid generation is
# rejected by the provenance published last.
cp -- "$CONFIG_OUT_DIR/aiplayerbot.conf" "$TMP/aiplayerbot.first-generation"
export AIPLAYERBOT_MIN_BOTS=4
export AIPLAYERBOT_MAX_BOTS=8
bash "$ROOT/deploy/compose/render-config.sh" >/dev/null
cp -- "$TMP/aiplayerbot.first-generation" "$CONFIG_OUT_DIR/aiplayerbot.conf"
if bash "$ROOT/deploy/compose/verify-config.sh" >/dev/null 2>&1; then
    echo "ERROR: verifier accepted a mixed generation" >&2
    exit 1
fi

export AIPLAYERBOT_MIN_BOTS=3
export AIPLAYERBOT_MAX_BOTS=7
bash "$ROOT/deploy/compose/render-config.sh" >/dev/null
bash "$ROOT/deploy/compose/verify-config.sh" >/dev/null
assert_rendered_contract
echo "config semantic provenance test passed"
