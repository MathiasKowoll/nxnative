#!/bin/sh
# Build the optional GPL offline adapter against a separate Eglantine checkout.
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: build_nvn2_ampere_bridge.sh EGLANTINE_SOURCE [OUTPUT]" >&2
    exit 2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$script_dir/build_nvn2_ampere_bridge.py" "$@"
