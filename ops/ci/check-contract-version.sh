#!/usr/bin/env bash
#
# The bot-brain contract version is declared twice, by hand, in two languages:
#
#   services/bot-brain/contract/version.go   VersionMajor / VersionMinor
#   modules/mod-bot-brain/src/BotBrainWire.h kContractMajor / kContractMinor
#
# BotBrainWire.h says "Must track services/bot-brain/contract/version.go" and,
# until this script, nothing enforced it. Both test suites could stay green
# while the two drifted apart, and the first symptom in production would be the
# handshake failing closed on every worldserver start - or worse, a MINOR skew
# that does not fail closed and silently changes what fields mean.
#
# This is deliberately a grep and not a parser. The declarations are two
# constants; anything cleverer would be harder to read than the thing it checks.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
go_file="$root/services/bot-brain/contract/version.go"
cpp_file="$root/modules/mod-bot-brain/src/BotBrainWire.h"

for f in "$go_file" "$cpp_file"; do
    [ -f "$f" ] || { echo "::error::missing $f"; exit 1; }
done

# `VersionMajor = 1` in a const block.
go_major=$(grep -oE '^[[:space:]]*VersionMajor[[:space:]]*=[[:space:]]*[0-9]+' "$go_file" | grep -oE '[0-9]+$' || true)
go_minor=$(grep -oE '^[[:space:]]*VersionMinor[[:space:]]*=[[:space:]]*[0-9]+' "$go_file" | grep -oE '[0-9]+$' || true)

# `int constexpr kContractMajor = 1;`
cpp_major=$(grep -oE 'kContractMajor[[:space:]]*=[[:space:]]*[0-9]+' "$cpp_file" | grep -oE '[0-9]+$' || true)
cpp_minor=$(grep -oE 'kContractMinor[[:space:]]*=[[:space:]]*[0-9]+' "$cpp_file" | grep -oE '[0-9]+$' || true)

for pair in "go_major:$go_major" "go_minor:$go_minor" "cpp_major:$cpp_major" "cpp_minor:$cpp_minor"; do
    name=${pair%%:*}; value=${pair#*:}
    if [ -z "$value" ]; then
        echo "::error::could not read $name - the declaration was reworded, so this check stopped checking."
        echo "  Look at $go_file and $cpp_file, then fix the pattern in $0."
        exit 1
    fi
done

echo "go  : ${go_major}.${go_minor}   ($go_file)"
echo "c++ : ${cpp_major}.${cpp_minor}   ($cpp_file)"

status=0

if [ "$go_major" != "$cpp_major" ]; then
    echo "::error::contract MAJOR differs: Go says $go_major, C++ says $cpp_major."
    echo "  A major mismatch fails the handshake closed, so every bot silently stops planning."
    status=1
fi

if [ "$go_minor" != "$cpp_minor" ]; then
    echo "::error::contract MINOR differs: Go says $go_minor, C++ says $cpp_minor."
    echo "  Minor skew does NOT fail closed - it negotiates down - so a field one side"
    echo "  believes it is sending is quietly not read. Move both declarations together."
    status=1
fi

# The golden fixtures carry the version too, so a bump that forgets them leaves
# the cross-language tests asserting the old contract.
golden="$root/contracts/bot-brain/v1/golden"
if [ -d "$golden" ]; then
    want="\"contract_version\": \"${go_major}.${go_minor}\""
    for f in "$golden/plan-request.json" "$golden/plan-response.json"; do
        [ -f "$f" ] || continue
        if ! grep -q "$want" "$f"; then
            echo "::error::$(basename "$f") does not declare ${go_major}.${go_minor} - the fixture is testing an older contract."
            status=1
        fi
    done
    if [ -f "$golden/contract-info.json" ] && ! grep -q "\"version\": \"${go_major}.${go_minor}\"" "$golden/contract-info.json"; then
        echo "::error::contract-info.json does not declare ${go_major}.${go_minor}."
        status=1
    fi
fi

[ "$status" -eq 0 ] && echo "contract version agrees across Go, C++ and the golden fixtures"
exit "$status"
