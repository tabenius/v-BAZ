#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for tool in mkfs.ext4 blkid debugfs; do
    command -v "$tool" >/dev/null 2>&1 || { echo "$tool not installed; skipping Kali persistence test"; exit 0; }
done
work=$(mktemp -d)
cleanup(){ rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
sh "$repo/tools/usb/prepare-kali-persistence.sh" "$work" 64 >/dev/null
image="$work/guests/kali/persistence.raw"
[ "$(blkid -s LABEL -o value "$image")" = persistence ]
[ "$(blkid -s TYPE -o value "$image")" = ext4 ]
[ "$(debugfs -R 'cat persistence.conf' "$image" 2>/dev/null)" = '/ union' ]
grep -q '"schema": "vbaz.kali-persistence.v1"' "$work/guests/kali/persistence.json"
if sh "$repo/tools/usb/prepare-kali-persistence.sh" "$work" 64 >/dev/null 2>&1; then
    echo "existing persistence state was overwritten" >&2
    exit 1
fi
echo "Kali persistence tests passed"
