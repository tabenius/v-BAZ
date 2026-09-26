#!/bin/sh
# Create a partitioned image container. Alpine/UEFI installation is a later gate.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
config="$repo/config/vbaz-usb.example.json"; output="$repo/out/vbaz-usb-amd64.raw"; dry_run=0; populate=0; kali=0; fetch_kali=0; kali_iso=; kali_sha256=
usage(){ echo "usage: $0 [--config FILE] [--output FILE] [--populate-host] [--prepare-kali] [--fetch-kali | --kali-iso FILE --kali-iso-sha256 HEX] [--dry-run]"; }
while [ "$#" -gt 0 ]; do case "$1" in --config) config=$2; shift 2;; --output) output=$2; shift 2;; --populate-host) populate=1; shift;; --prepare-kali) kali=1; shift;; --fetch-kali) kali=1; fetch_kali=1; shift;; --kali-iso) kali_iso=$2; shift 2;; --kali-iso-sha256) kali_sha256=$2; shift 2;; --dry-run) dry_run=1; shift;; -h|--help) usage; exit 0;; *) usage >&2; exit 2;; esac; done
[ -z "$kali_iso" ] && [ -z "$kali_sha256" ] || { kali=1; [ -n "$kali_iso" ] && [ -n "$kali_sha256" ] || { echo "--kali-iso and --kali-iso-sha256 must be supplied together" >&2; exit 2; }; }
[ "$fetch_kali" -eq 0 ] || { [ -z "$kali_iso" ] && [ -z "$kali_sha256" ] || { echo "--fetch-kali cannot be combined with an explicit ISO" >&2; exit 2; }; }
sh "$repo/tools/usb/validate-config.sh" "$config" >/dev/null
layout=$(sh "$repo/tools/usb/layout.sh" "$(jq -r .image.size_mib "$config")" "$(jq -r .host.root_slot_size_mib "$config")"); eval "$layout"
printf '%s\nOUTPUT=%s\n' "$layout" "$output"; [ "$dry_run" -eq 0 ] || { echo DRY_RUN=1; exit 0; }
case "$output" in /dev/*) echo "refusing block-device output: $output" >&2; exit 2;; esac
[ "$(id -u)" -eq 0 ] || { echo "root is required for loop devices" >&2; exit 2; }
for x in sgdisk losetup mkfs.vfat mkfs.ext4; do command -v "$x" >/dev/null 2>&1 || { echo "missing required tool: $x" >&2; exit 2; }; done
[ ! -e "$output" ] || { echo "refusing to overwrite: $output" >&2; exit 2; }
build_work=$(mktemp -d)
cleanup(){ [ -z "${loopdev:-}" ] || losetup -d "$loopdev" 2>/dev/null || true; rm -rf "$build_work"; }; trap cleanup EXIT HUP INT TERM
if [ "$fetch_kali" -eq 1 ]; then
    kali_iso="$build_work/kali-live.iso"
    kali_sha256=$(jq -er '.guests[] | select(.id == "kali") | .media.sha256' "$config")
    kali_url=$(jq -er '.guests[] | select(.id == "kali") | .media.url' "$config")
    sh "$repo/tools/usb/fetch-kali-iso.sh" "$kali_url" "$kali_sha256" "$kali_iso"
fi
mkdir -p "$(dirname "$output")"; truncate -s "${IMAGE_MIB}M" "$output"
sgdisk --clear --new=1:0:+${ESP_SIZE_MIB}M --typecode=1:ef00 --change-name=1:VBAZ_ESP --new=2:0:+${ROOT_A_SIZE_MIB}M --typecode=2:8300 --change-name=2:VBAZ_ROOT_A --new=3:0:+${ROOT_B_SIZE_MIB}M --typecode=3:8300 --change-name=3:VBAZ_ROOT_B --new=4:0:+${CONFIG_SIZE_MIB}M --typecode=4:8300 --change-name=4:VBAZ_CONFIG --new=5:0:0 --typecode=5:8300 --change-name=5:VBAZ_DATA "$output"
loopdev=$(losetup --find --show --partscan "$output")
mkfs.vfat -F 32 -n VBAZ_ESP "${loopdev}p1"; mkfs.ext4 -F -L VBAZ_ROOT_A "${loopdev}p2"; mkfs.ext4 -F -L VBAZ_ROOT_B "${loopdev}p3"; mkfs.ext4 -F -L VBAZ_CONFIG "${loopdev}p4"; mkfs.ext4 -F -L VBAZ_DATA "${loopdev}p5"; sync
if [ "$populate" -eq 1 ]; then
    sh "$repo/tools/usb/populate-host.sh" "$loopdev" "$(mktemp -d)" "$config"
    echo "bootable Alpine host image created: $output"
else
    echo "partitioned image container created: $output"; echo "not bootable yet: use --populate-host"
fi
if [ "$kali" -eq 1 ]; then
    sh "$repo/tools/usb/populate-kali-guest.sh" "$loopdev" "$(mktemp -d)" "$config" "$kali_iso" "$kali_sha256"
    echo "Kali guest storage prepared: $output"
fi
