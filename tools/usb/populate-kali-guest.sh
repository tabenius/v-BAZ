#!/bin/sh
# Prepare Phase 2 guest storage on the portable image's data partition.
set -eu
loopdev=${1:?usage: populate-kali-guest.sh LOOPDEV WORKDIR CONFIG [ISO SHA256]}
work=${2:?usage: populate-kali-guest.sh LOOPDEV WORKDIR CONFIG [ISO SHA256]}
config=${3:?usage: populate-kali-guest.sh LOOPDEV WORKDIR CONFIG [ISO SHA256]}
iso=${4:-}
iso_sha256=${5:-}
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
size_mib=$(jq -er '.guests[] | select(.id == "kali") | .persistence.size_mib' "$config")
[ -z "$iso" ] && [ -z "$iso_sha256" ] || {
    [ -n "$iso" ] && [ -n "$iso_sha256" ] || { echo "Kali ISO and SHA256 must be supplied together" >&2; exit 2; }
    [ -f "$iso" ] && [ -s "$iso" ] || { echo "Kali ISO not found or empty: $iso" >&2; exit 2; }
    actual=$(sha256sum "$iso" | awk '{print $1}')
    [ "$actual" = "$iso_sha256" ] || { echo "Kali ISO checksum mismatch" >&2; exit 2; }
}
mkdir -p "$work/data"
mount "${loopdev}p5" "$work/data"
cleanup(){ umount "$work/data" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
sh "$repo/tools/usb/prepare-kali-persistence.sh" "$work/data" "$size_mib"
[ -z "$iso" ] || sh "$repo/tools/usb/stage-kali-iso.sh" "$work/data" "$iso" "$iso_sha256"
sync
cleanup
trap - EXIT HUP INT TERM
