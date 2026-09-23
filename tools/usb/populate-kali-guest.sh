#!/bin/sh
# Prepare Phase 2 guest storage on the portable image's data partition.
set -eu
loopdev=${1:?usage: populate-kali-guest.sh LOOPDEV WORKDIR CONFIG}
work=${2:?usage: populate-kali-guest.sh LOOPDEV WORKDIR CONFIG}
config=${3:?usage: populate-kali-guest.sh LOOPDEV WORKDIR CONFIG}
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
size_mib=$(jq -er '.guests[] | select(.id == "kali") | .persistence.size_mib' "$config")
mkdir -p "$work/data"
mount "${loopdev}p5" "$work/data"
cleanup(){ umount "$work/data" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
sh "$repo/tools/usb/prepare-kali-persistence.sh" "$work/data" "$size_mib"
sync
cleanup
trap - EXIT HUP INT TERM
