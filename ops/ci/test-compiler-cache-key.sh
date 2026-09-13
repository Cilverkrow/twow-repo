#!/usr/bin/env bash
# Fast, container-free contract tests for the rolling compiler-cache namespace.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEY_SCRIPT="$ROOT/ops/ci/compiler-cache-key.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yml"

key() {
    CACHE_KEY_SCHEMA=2 \
    CACHE_OS=Linux \
    CACHE_ARCH=x86-64-v2 \
    CACHE_COMPILER=g++ \
    CACHE_COMPILER_VERSION="$1" \
    CACHE_TOOLCHAIN_PIN='sha256:toolchain-a' \
    CACHE_CMAKE_FLAGS="$2" \
    bash "$KEY_SCRIPT" | sed -n 's/^fingerprint=//p'
}

flags='CMAKE_BUILD_TYPE=Release;DEBUG_SYMBOLS=OFF;CMAKE_INSTALL_PREFIX=/opt/turtle;TW_ARCH=x86-64-v2;MODULES=static;BUILD_TESTING=ON;BUILD_PERSISTENT_ROSTER_ADAPTER_TESTS=ON'
same_a=$(key 14.2.0 "$flags")
same_b=$(key 14.2.0 "$flags")
changed_compiler=$(key 15.1.0 "$flags")
changed_abi=$(key 14.2.0 "${flags/TW_ARCH=x86-64-v2/TW_ARCH=native}")

[[ "$same_a" == "$same_b" ]] || { echo 'ERROR: identical contract is unstable' >&2; exit 1; }
[[ "$same_a" != "$changed_compiler" ]] || { echo 'ERROR: compiler change reused a cache contract' >&2; exit 1; }
[[ "$same_a" != "$changed_abi" ]] || { echo 'ERROR: ABI flag change reused a cache contract' >&2; exit 1; }

# A source commit/Core gitlink is intentionally absent above. ccache validates
# changed source content per translation unit, while unchanged units retain this
# compatible namespace and can hit.
grep -Fqx "      CI_CACHE_DEBUG_SYMBOLS: 'OFF'" "$WORKFLOW"
grep -Fqx '            -DCMAKE_BUILD_TYPE=Release \' "$WORKFLOW"
grep -Fqx '            -DDEBUG_SYMBOLS=${{ env.CI_CACHE_DEBUG_SYMBOLS }} \' "$WORKFLOW"
grep -Fqx '            -DCMAKE_INSTALL_PREFIX=/opt/turtle \' "$WORKFLOW"
grep -Fqx '            -DTW_ARCH=x86-64-v2 \' "$WORKFLOW"
grep -Fqx '            -DMODULES=static \' "$WORKFLOW"
grep -Fqx '            -DBUILD_TESTING=ON \' "$WORKFLOW"
grep -Fqx '            -DBUILD_PERSISTENT_ROSTER_ADAPTER_TESTS=ON \' "$WORKFLOW"
cache_contract=$(sed -n '/cache_cmake_flags=/,/contract=/p' "$WORKFLOW")
for component in CMAKE_BUILD_TYPE=Release DEBUG_SYMBOLS=OFF \
                 CMAKE_INSTALL_PREFIX=/opt/turtle TW_ARCH=x86-64-v2 \
                 MODULES=static BUILD_TESTING=ON \
                 BUILD_PERSISTENT_ROSTER_ADAPTER_TESTS=ON; do
    printf '%s\n' "$cache_contract" | grep -Fq "$component"
done
grep -Fqx '          key: ci-gcc-v2-${{ steps.compiler-cache-contract.outputs.fingerprint }}-${{ github.run_id }}' "$WORKFLOW"
grep -Fqx '            ci-gcc-v2-${{ steps.compiler-cache-contract.outputs.fingerprint }}-' "$WORKFLOW"
grep -Fqx '          keep="ci-gcc-v2-${{ steps.compiler-cache-contract.outputs.fingerprint }}-${{ github.run_id }}"' "$WORKFLOW"

cache_restore=$(sed -n '/- name: Restore the compiler cache/,/- name: Report restored compiler cache/p' "$WORKFLOW")
if printf '%s\n' "$cache_restore" | grep -Eq 'github\.(sha|event\.pull_request)'; then
    echo 'ERROR: source revision leaked into compiler cache restore key' >&2
    exit 1
fi
if grep -Fq 'CCACHE_COMPILERCHECK=' "$ROOT/ops/ci/in-builder.sh"; then
    echo 'ERROR: ccache compiler validation must retain its safe default' >&2
    exit 1
fi

printf '%s\n' 'same_toolchain_new_commit=compatible_restore'
printf '%s\n' 'changed_compiler=no_compatible_restore'
printf '%s\n' 'changed_abi_flag=no_compatible_restore'
printf '%s\n' 'changed_core_source=compatible_namespace_ccache_validates_content'
