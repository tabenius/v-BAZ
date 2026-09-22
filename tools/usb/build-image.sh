#!/bin/sh
# Create a partitioned image container. Alpine/UEFI installation is a later gate.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
config="$repo/config/vbaz-usb.example.json"; output="$repo/out/vbaz-usb-amd64.raw"; dry_run=0
usage(){ echo "usage: $0 [--config FILE] [--output FILE] [--dry-run]"; }
while [ "$#" -gt 0 ]; do case "$1" in --config) config=$2; shift 2;; --output) output=$2; shift 2;; --dry-run) dry_run=1; shift;; -h|--help) usage; exit 0;; *) usage >&2; exit 2;; esac; done
"$repo/tools/usb/validate-config.sh" "$config" >/dev/null
layout=$("$repo/tools/usb/layout.sh" "$(jq -r .image.size_mib "$config")" "$(jq -r .host.root_slot_size_mib "$config")"); eval "$layout"
printf '%s\nOUTPUT=%s\n' "$layout" "$output"; [ "$dry_run" -eq 0 ] || { echo DRY_RUN=1; exit 0; }
case "$output" in /dev/*) echo "refusing block-device output: $output" >&2; exit 2;; esac
[ "$(id -u)" -eq 0 ] || { echo "root is required for loop devices" >&2; exit 2; }
for x in sgdisk losetup mkfs.vfat mkfs.ext4; do command -v "$x" >/dev/null 2>&1 || { echo "missing required tool: $x" >&2; exit 2; }; done
[ ! -e "$output" ] || { echo "refusing to overwrite: $output" >&2; exit 2; }
mkdir -p "$(dirname "$output")"; truncate -s "${IMAGE_MIB}M" "$output"
cleanup(){ [ -z "${loopdev:-}" ] || losetup -d "$loopdev" 2>/dev/null || true; }; trap cleanup EXIT HUP INT TERM
sgdisk --clear --new=1:0:+${ESP_SIZE_MIB}M --typecode=1:ef00 --change-name=1:VBAZ_ESP --new=2:0:+${ROOT_A_SIZE_MIB}M --typecode=2:8300 --change-name=2:VBAZ_ROOT_A --new=3:0:+${ROOT_B_SIZE_MIB}M --typecode=3:8300 --change-name=3:VBAZ_ROOT_B --new=4:0:+${CONFIG_SIZE_MIB}M --typecode=4:8300 --change-name=4:VBAZ_CONFIG --new=5:0:0 --typecode=5:8300 --change-name=5:VBAZ_DATA "$output"
loopdev=$(losetup --find --show --partscan "$output")
mkfs.vfat -F 32 -n VBAZ_ESP "${loopdev}p1"; mkfs.ext4 -F -L VBAZ_ROOT_A "${loopdev}p2"; mkfs.ext4 -F -L VBAZ_ROOT_B "${loopdev}p3"; mkfs.ext4 -F -L VBAZ_CONFIG "${loopdev}p4"; mkfs.ext4 -F -L VBAZ_DATA "${loopdev}p5"; sync
echo "partitioned image container created: $output"; echo "not bootable yet: Alpine/UEFI installation is next"
