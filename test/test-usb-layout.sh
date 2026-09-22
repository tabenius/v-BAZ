#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
layout=$("$repo/tools/usb/layout.sh" 65536 6144); eval "$layout"
[ "$ESP_START_MIB" -eq 1 ]; [ "$ROOT_A_START_MIB" -eq 1025 ]; [ "$ROOT_B_START_MIB" -eq 7169 ]; [ "$CONFIG_START_MIB" -eq 13313 ]; [ "$DATA_START_MIB" -eq 13825 ]; [ "$DATA_SIZE_MIB" -eq 51710 ]
if "$repo/tools/usb/layout.sh" 16384 6144 >/dev/null 2>&1; then echo "undersized image accepted" >&2; exit 1; fi
"$repo/tools/usb/validate-config.sh" "$repo/config/vbaz-usb.example.json"
plan=$("$repo/tools/usb/build-image.sh" --output /tmp/must-not-exist.raw --dry-run)
echo "$plan" | grep -q '^DATA_SIZE_MIB=51710$'; echo "$plan" | grep -q '^DRY_RUN=1$'; [ ! -e /tmp/must-not-exist.raw ]
echo "USB layout tests passed"
