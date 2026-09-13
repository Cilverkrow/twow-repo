#!/usr/bin/env bash
# Print the compiler-cache contract fingerprint used by ci.yml.
#
# Source revisions are deliberately not inputs. ccache keys individual compiler
# invocations from their source and header content, so a Core/submodule change
# causes only affected translation units to miss; making every source revision
# a namespace change would discard all unaffected objects.

set -euo pipefail

for variable in CACHE_KEY_SCHEMA CACHE_OS CACHE_ARCH CACHE_COMPILER \
                CACHE_COMPILER_VERSION CACHE_TOOLCHAIN_PIN \
                CACHE_CMAKE_FLAGS; do
    value=${!variable:-}
    if [[ -z "$value" || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        echo "ERROR: $variable must be a non-empty single-line value" >&2
        exit 1
    fi
done

contract=$(
    printf '%s\n' \
        "schema=$CACHE_KEY_SCHEMA" \
        "os=$CACHE_OS" \
        "architecture=$CACHE_ARCH" \
        "compiler=$CACHE_COMPILER" \
        "compiler_version=$CACHE_COMPILER_VERSION" \
        "toolchain_pin=$CACHE_TOOLCHAIN_PIN" \
        "cmake_flags=$CACHE_CMAKE_FLAGS"
)

printf '%s\n' "$contract"
printf 'fingerprint=%s\n' "$(printf '%s\n' "$contract" | sha256sum | awk '{print $1}')"
