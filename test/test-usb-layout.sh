#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
layout=$(sh "$repo/tools/usb/layout.sh" 65536 6144); eval "$layout"
[ "$ESP_START_MIB" -eq 1 ]; [ "$ROOT_A_START_MIB" -eq 1025 ]; [ "$ROOT_B_START_MIB" -eq 7169 ]; [ "$CONFIG_START_MIB" -eq 13313 ]; [ "$DATA_START_MIB" -eq 13825 ]; [ "$DATA_SIZE_MIB" -eq 51710 ]
if sh "$repo/tools/usb/layout.sh" 16384 6144 >/dev/null 2>&1; then echo "undersized image accepted" >&2; exit 1; fi
sh "$repo/tools/usb/validate-config.sh" "$repo/config/vbaz-usb.example.json"
plan=$(sh "$repo/tools/usb/build-image.sh" --output /tmp/must-not-exist.raw --dry-run)
echo "$plan" | grep -q '^DATA_SIZE_MIB=51710$'; echo "$plan" | grep -q '^DRY_RUN=1$'; [ ! -e /tmp/must-not-exist.raw ]
if sh "$repo/tools/usb/build-image.sh" --kali-iso /tmp/example.iso --dry-run >/dev/null 2>&1; then
    echo "Kali ISO without checksum was accepted" >&2
    exit 1
fi
if sh "$repo/tools/usb/build-image.sh" --kali-iso-sha256 "$(printf '0%.0s' $(seq 1 64))" --dry-run >/dev/null 2>&1; then
    echo "Kali checksum without ISO was accepted" >&2
    exit 1
fi
fetch_plan=$(sh "$repo/tools/usb/build-image.sh" --fetch-kali --dry-run)
echo "$fetch_plan" | grep -q '^DRY_RUN=1$'
if sh "$repo/tools/usb/build-image.sh" --fetch-kali --kali-iso /tmp/example.iso --kali-iso-sha256 "$(printf '0%.0s' $(seq 1 64))" --dry-run >/dev/null 2>&1; then
    echo "fetched and explicit Kali media were accepted together" >&2
    exit 1
fi
echo "USB layout tests passed"
