#!/bin/sh
# Build the optional GPL offline adapter against a separate Eglantine checkout.
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "usage: build_nvn2_ampere_bridge.sh EGLANTINE_SOURCE [OUTPUT]" >&2
    exit 2
fi

eglantine_source=$1
output=${2:-nvn2_ampere_bridge}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
header="$eglantine_source/src/shader_recompiler/frontend/ampere/program_capture.h"
if [ ! -f "$header" ]; then
    echo "missing Eglantine Ampere header: $header" >&2
    exit 2
fi

exec clang++ -std=c++20 -O2 -I "$eglantine_source/src" \
    "$script_dir/nvn2_ampere_bridge.cpp" -o "$output"
