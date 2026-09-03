#!/usr/bin/env bash
# Fail before an expensive CI job starts when its backing filesystem cannot
# hold the expected workload. An explicit available-KiB value makes the gate
# deterministic and permits a real negative test without filling a disk.

set -euo pipefail

label="filesystem"
path="."
minimum_gib=""
available_kib=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --label)
            label=${2:?missing value for --label}
            shift 2
            ;;
        --path)
            path=${2:?missing value for --path}
            shift 2
            ;;
        --minimum-gib)
            minimum_gib=${2:?missing value for --minimum-gib}
            shift 2
            ;;
        --available-kib)
            available_kib=${2:?missing value for --available-kib}
            shift 2
            ;;
        *)
            echo "usage: $0 --minimum-gib N [--path PATH] [--label LABEL] [--available-kib N]" >&2
            exit 2
            ;;
    esac
done

case "$minimum_gib" in
    ''|*[!0-9]*)
        echo "::error::capacity minimum must be a positive integer GiB value" >&2
        exit 2
        ;;
esac
[ "$minimum_gib" -gt 0 ] || {
    echo "::error::capacity minimum must be greater than zero" >&2
    exit 2
}

if [ -z "$available_kib" ]; then
    [ -e "$path" ] || {
        echo "::error::capacity probe path does not exist: $path" >&2
        exit 2
    }
    available_kib=$(df -Pk -- "$path" | awk 'END { print $4 }')
fi

case "$available_kib" in
    ''|*[!0-9]*)
        echo "::error::capacity probe for $label did not return an integer KiB value" >&2
        exit 2
        ;;
esac

required_kib=$((minimum_gib * 1024 * 1024))
available_gib=$(awk -v kib="$available_kib" 'BEGIN { printf "%.2f", kib / 1024 / 1024 }')
echo "capacity label=$label available_kib=$available_kib available_gib=$available_gib required_gib=$minimum_gib"

if [ "$available_kib" -lt "$required_kib" ]; then
    echo "::error::insufficient $label capacity: ${available_gib} GiB available, ${minimum_gib} GiB required" >&2
    exit 1
fi

echo "capacity gate passed for $label"
