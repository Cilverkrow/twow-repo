#!/usr/bin/env bash
# Validate the dynamically published port used by the disposable CI database.
# Port 3307 belongs to the Windows production/runtime layout and is forbidden.

set -euo pipefail

port=${1:-}
case "$port" in
    ''|*[!0-9]*)
        echo "::error::CI database port is missing or non-numeric" >&2
        exit 2
        ;;
esac

if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "::error::CI database port is outside the TCP range: $port" >&2
    exit 2
fi

if [ "$port" -eq 3307 ]; then
    echo "::error::refusing production/runtime database port 3307; CI must use its disposable container" >&2
    exit 1
fi

echo "disposable CI database port accepted: $port"
