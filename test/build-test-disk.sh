#!/bin/sh
# v-BAZ :: build a virtual UEFI disk that mimics the post-Windows-installer
# state, so the Alpine boot+provision chain can be smoke-tested under QEMU.
#
# It lays down a GPT disk with:
#   p1 EFI System Partition (FAT32) - staged like the real ESP:
#        /EFI/vbaz/{refind_x64.efi,vmlinuz-lts,initramfs-lts,modloop-lts,
#                   refind.conf, drivers_x64/ext4_x64.efi}
#        /EFI/BOOT/BOOTX64.EFI  (rEFInd, so OVMF auto-boots it - stands in for
#                                the Windows Boot Manager entry)
#        /vbaz.apkovl.tar.gz    (overlay auto-loaded by the initramfs)
#   p2 VBAZ_ROOT  (tagged, UNFORMATTED - the provisioner formats it)
#   p3 VBAZ_ZFS   (tagged, UNFORMATTED - the provisioner makes the pool)
#
# This does NOT test the Windows PowerShell side (partitioning/bcdedit); that
# needs a Windows VM. It tests everything from rEFInd onwards.
#
# Prereqs: sgdisk (gptfdisk), mtools (mformat/mcopy/mmd), and one of
#          unzip / bsdtar, plus wget or curl. On Alpine:
#            apk add gptfdisk mtools unzip wget
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CACHE="$REPO/test/cache"
OUT="${OUT:-$REPO/test/vbaz-test.img}"
ENVF="${ENVF:-$REPO/test/test.env}"
mkdir -p "$CACHE"

# Sizes (MiB). Small but enough for a light 'base virt zfs' install.
ESP_MB="${ESP_MB:-256}"
WINSTUB_MB="${WINSTUB_MB:-512}"   # a stand-in "Windows C:" partition (must be ignored)
ROOT_MB="${ROOT_MB:-6144}"        # host X:
ZFS_MB="${ZFS_MB:-4096}"          # guests D:
# ZFS_SEPARATE=1 puts VBAZ_ZFS on a SECOND disk image (models a separate D: disk).
ZFS_SEPARATE="${ZFS_SEPARATE:-0}"
OUT2="${OUT2:-$REPO/test/vbaz-test-zfs.img}"
VERBOSE="${VERBOSE:-0}"
LOG="${LOG:-$REPO/test/build-test-disk.log}"

ESP_GUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
MSDATA_GUID=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7

# Everything also goes to a build log by default; -v/VERBOSE=1 adds tracing.
[ "${1:-}" = "-v" ] && VERBOSE=1
# Tee all output to the log without bashisms (process substitution): use a FIFO.
if command -v mkfifo >/dev/null 2>&1; then
    _fifo="${TMPDIR:-/tmp}/vbaz-buildlog.$$"
    if mkfifo "$_fifo" 2>/dev/null; then
        tee -a "$LOG" < "$_fifo" &
        _teepid=$!
        exec > "$_fifo" 2>&1
        trap 'rm -f "$_fifo"; wait "$_teepid" 2>/dev/null' EXIT
    fi
fi
[ "$VERBOSE" = "1" ] && set -x
echo "=== build-test-disk $(date) (log: $LOG) ==="

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1" >&2; MISSING=1; }; }
MISSING=0
need sgdisk; need mformat; need mcopy; need mmd
command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || { echo "need wget or curl" >&2; MISSING=1; }
command -v unzip >/dev/null 2>&1 || command -v bsdtar >/dev/null 2>&1 || { echo "need unzip or bsdtar (for rEFInd)" >&2; MISSING=1; }
[ "$MISSING" = 0 ] || { echo "install the missing tools and retry." >&2; exit 1; }

# shellcheck disable=SC1090
. "$ENVF"
: "${VBAZ_BRANCH:?}" "${VBAZ_ARCH:?}" "${VBAZ_FLAVOR:?}" "${VBAZ_MIRROR:?}" "${VBAZ_ESPSUBDIR:?}"
VER="${VBAZ_VERSION:-3.21.0}"

fetch() { # url dest
    [ -f "$2" ] && { echo "cached $(basename "$2")"; return 0; }
    echo "download $1"
    if command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"; else curl -fsSL -o "$2" "$1"; fi
}

# --- Alpine netboot files -------------------------------------------------
base="$VBAZ_MIRROR/$VBAZ_BRANCH/releases/$VBAZ_ARCH"
nb=""
for cand in "netboot-$VER" "netboot"; do
    if fetch "$base/$cand/vmlinuz-$VBAZ_FLAVOR" "$CACHE/vmlinuz" 2>/dev/null; then nb="$base/$cand"; break; fi
done
[ -n "$nb" ] || { echo "could not locate Alpine netboot files under $base" >&2; exit 1; }
fetch "$nb/initramfs-$VBAZ_FLAVOR" "$CACHE/initramfs"
fetch "$nb/modloop-$VBAZ_FLAVOR"   "$CACHE/modloop"

# --- rEFInd ---------------------------------------------------------------
REFIND_EFI="${REFIND_EFI:-}"
EXT4_EFI="${EXT4_EFI:-}"
if [ -z "$REFIND_EFI" ]; then
    fetch "https://sourceforge.net/projects/refind/files/latest/download" "$CACHE/refind.zip"
    rm -rf "$CACHE/refind"; mkdir -p "$CACHE/refind"
    if command -v unzip >/dev/null 2>&1; then unzip -qo "$CACHE/refind.zip" -d "$CACHE/refind";
    else bsdtar -xf "$CACHE/refind.zip" -C "$CACHE/refind"; fi
    REFIND_EFI=$(find "$CACHE/refind" -name 'refind_x64.efi' | head -n1)
    EXT4_EFI=$(find "$CACHE/refind" -name 'ext4_x64.efi' | head -n1)
fi
[ -n "$REFIND_EFI" ] && [ -f "$REFIND_EFI" ] || { echo "refind_x64.efi not found" >&2; exit 1; }

# --- refind.conf from the template ---------------------------------------
conf="$CACHE/refind.conf"
sed -e "s#@@ESPSUBDIR@@#$VBAZ_ESPSUBDIR#g" \
    -e "s#@@ENTRYNAME@@#v-BAZ Alpine (test)#g" \
    -e "s#@@MODLOOP_URL@@#$nb/modloop-$VBAZ_FLAVOR#g" \
    -e "s#@@ALPINE_REPO@@#$VBAZ_MIRROR/$VBAZ_BRANCH/main#g" \
    -e "s#@@ROOTLABEL@@#${VBAZ_ROOTLABEL:-VBAZ_ROOT}#g" \
    "$REPO/refind/refind.conf.template" > "$conf"

# --- overlay --------------------------------------------------------------
sh "$REPO/test/build-apkovl.sh" "$CACHE/vbaz.apkovl.tar.gz" "$ENVF"

# --- assemble the ESP FAT image ------------------------------------------
esp="$CACHE/esp.img"
rm -f "$esp"; dd if=/dev/zero of="$esp" bs=1M count="$ESP_MB" status=none
mformat -i "$esp" -F ::
mmd -i "$esp" ::/EFI ::/EFI/BOOT "::/EFI/$VBAZ_ESPSUBDIR" "::/EFI/$VBAZ_ESPSUBDIR/drivers_x64"
mcopy -i "$esp" "$REFIND_EFI" "::/EFI/$VBAZ_ESPSUBDIR/refind_x64.efi"
mcopy -i "$esp" "$REFIND_EFI" "::/EFI/BOOT/BOOTX64.EFI"
mcopy -i "$esp" "$conf" "::/EFI/BOOT/refind.conf"
mcopy -i "$esp" "$conf" "::/EFI/$VBAZ_ESPSUBDIR/refind.conf"
mcopy -i "$esp" "$CACHE/vmlinuz"   "::/EFI/$VBAZ_ESPSUBDIR/vmlinuz-lts"
mcopy -i "$esp" "$CACHE/initramfs" "::/EFI/$VBAZ_ESPSUBDIR/initramfs-lts"
mcopy -i "$esp" "$CACHE/modloop"   "::/EFI/$VBAZ_ESPSUBDIR/modloop-lts"
[ -n "$EXT4_EFI" ] && [ -f "$EXT4_EFI" ] && mcopy -i "$esp" "$EXT4_EFI" "::/EFI/$VBAZ_ESPSUBDIR/drivers_x64/ext4_x64.efi"
mcopy -i "$esp" "$CACHE/vbaz.apkovl.tar.gz" "::/vbaz.apkovl.tar.gz"
# boot splash (referenced by refind.conf banner)
[ -f "$REPO/assets/original/vbaz-splash.png" ] && \
    mcopy -i "$esp" "$REPO/assets/original/vbaz-splash.png" "::/EFI/$VBAZ_ESPSUBDIR/splash.png"

# --- lay out the GPT disk and splice the ESP in --------------------------
# Layout models the real machine: ESP + a Windows-stub (Microsoft basic data,
# which the provisioner MUST ignore) + VBAZ_ROOT (host X:). VBAZ_ZFS (guests
# D:) goes on this disk too, or on a second disk when ZFS_SEPARATE=1.
ROOTTYPE="${VBAZ_ROOTTYPE:-0FC63DAF-8483-4772-8E79-3D69D8477DE4}"
ZFSTYPE="${VBAZ_ZFS_TYPE:-6A898CC3-1DD2-11B2-99A6-080020736631}"

total_mb=$((ESP_MB + WINSTUB_MB + ROOT_MB + 16))
[ "$ZFS_SEPARATE" = "1" ] || total_mb=$((total_mb + ZFS_MB))
rm -f "$OUT"; dd if=/dev/zero of="$OUT" bs=1M count="$total_mb" status=none
sgdisk -Z "$OUT" >/dev/null
sgdisk -n 1:2048:+${ESP_MB}M     -t 1:"$ESP_GUID"     -c 1:"EFI System"        "$OUT" >/dev/null
sgdisk -n 2:0:+${WINSTUB_MB}M    -t 2:"$MSDATA_GUID"  -c 2:"Windows (stub)"     "$OUT" >/dev/null
if [ "$ZFS_SEPARATE" = "1" ]; then
    sgdisk -n 3:0:0              -t 3:"$ROOTTYPE"      -c 3:"VBAZ_ROOT"          "$OUT" >/dev/null
    # second disk carries only the ZFS partition
    rm -f "$OUT2"; dd if=/dev/zero of="$OUT2" bs=1M count=$((ZFS_MB + 8)) status=none
    sgdisk -Z "$OUT2" >/dev/null
    sgdisk -n 1:2048:0          -t 1:"$ZFSTYPE"       -c 1:"VBAZ_ZFS"           "$OUT2" >/dev/null
else
    sgdisk -n 3:0:+${ROOT_MB}M  -t 3:"$ROOTTYPE"      -c 3:"VBAZ_ROOT"          "$OUT" >/dev/null
    sgdisk -n 4:0:0             -t 4:"$ZFSTYPE"       -c 4:"VBAZ_ZFS"           "$OUT" >/dev/null
fi

start=$(sgdisk -i 1 "$OUT" | awk -F'[ (]+' '/First sector/{print $3}')
[ -n "$start" ] || { echo "could not read ESP start sector" >&2; exit 1; }
dd if="$esp" of="$OUT" bs=512 seek="$start" conv=notrunc status=none

echo
echo "built $OUT"
sgdisk -p "$OUT" | sed 's/^/  /'
if [ "$ZFS_SEPARATE" = "1" ]; then
    echo "built $OUT2 (ZFS disk)"; sgdisk -p "$OUT2" | sed 's/^/  /'
    echo; echo "next: sh test/run-smoke.sh --disk $OUT --disk2 $OUT2"
else
    echo; echo "next: sh test/run-smoke.sh --disk $OUT"
fi
