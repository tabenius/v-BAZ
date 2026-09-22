#!/bin/sh
set -eu
input=${1:?usage: convert-vhdx.sh INPUT.raw OUTPUT.vhdx}; output=${2:?usage: convert-vhdx.sh INPUT.raw OUTPUT.vhdx}
command -v qemu-img >/dev/null 2>&1 || { echo "qemu-img is required" >&2; exit 2; }
[ -f "$input" ] || { echo "input not found: $input" >&2; exit 2; }; [ ! -e "$output" ] || { echo "refusing to overwrite: $output" >&2; exit 2; }
qemu-img convert -p -f raw -O vhdx -o subformat=fixed "$input" "$output"; qemu-img check -f vhdx "$output"
