#!/bin/sh
# Populate both Alpine root slots and the ESP of a partitioned USB image.
set -eu
loopdev=${1:?usage: populate-host.sh LOOPDEV WORKDIR}
work=${2:?usage: populate-host.sh LOOPDEV WORKDIR}
version=${ALPINE_VERSION:-3.21.0}
branch=${ALPINE_BRANCH:-v3.21}
mirror=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
arch=x86_64
mkdir -p "$work/cache" "$work/esp" "$work/root-a" "$work/root-b"

fetch(){ [ -s "$2" ] || curl --fail --location --retry 4 --output "$2" "$1"; }
release="$mirror/$branch/releases/$arch"
fetch "$release/alpine-minirootfs-$version-$arch.tar.gz" "$work/cache/minirootfs.tar.gz"
fetch "$release/alpine-minirootfs-$version-$arch.tar.gz.sha256" "$work/cache/minirootfs.sha256"
(cd "$work/cache" && sed 's#  alpine-minirootfs[^ ]*#  minirootfs.tar.gz#' minirootfs.sha256 | sha256sum -c -)

netboot_archive="alpine-netboot-$version-$arch.tar.gz"
fetch "$release/$netboot_archive" "$work/cache/netboot.tar.gz"
fetch "$release/$netboot_archive.sha256" "$work/cache/netboot.sha256"
(cd "$work/cache" && sed "s#  $netboot_archive#  netboot.tar.gz#" netboot.sha256 | sha256sum -c -)
tar -xzf "$work/cache/netboot.tar.gz" -C "$work/cache" vmlinuz-lts initramfs-lts modloop-lts

mount "${loopdev}p1" "$work/esp"
mount "${loopdev}p2" "$work/root-a"
mount "${loopdev}p3" "$work/root-b"
cleanup(){ umount "$work/root-b" "$work/root-a" "$work/esp" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

for slot in a b; do
    root="$work/root-$slot"
    tar -xzf "$work/cache/minirootfs.tar.gz" -C "$root"
    label=$(printf 'VBAZ_ROOT_%s' "$slot" | tr 'a-z' 'A-Z')
    printf 'LABEL=%s / ext4 rw,relatime 0 1\n' "$label" > "$root/etc/fstab"
    printf 'vbaz\n' > "$root/etc/hostname"
    printf 'v-BAZ portable host slot %s\n' "$(printf %s "$slot" | tr a-z A-Z)" > "$root/etc/issue"
    mkdir -p "$root/etc/local.d"
    cat > "$root/etc/local.d/vbaz-portable.start" <<EOF
#!/bin/sh
echo 'vbaz-portable: slot $(printf %s "$slot" | tr a-z A-Z) booted' >/dev/ttyS0
EOF
    chmod 0755 "$root/etc/local.d/vbaz-portable.start"
    mkdir -p "$root/etc/runlevels/default"
    ln -sf /etc/init.d/local "$root/etc/runlevels/default/local"
done

bootefi=""
for p in /usr/lib/systemd/boot/efi/systemd-bootx64.efi /usr/lib/systemd/boot/efi/systemd-bootx64.efi.stub; do
    [ -f "$p" ] && { bootefi=$p; break; }
done
[ -n "$bootefi" ] || { echo "systemd-bootx64.efi not found" >&2; exit 1; }
mkdir -p "$work/esp/EFI/BOOT" "$work/esp/EFI/vbaz" "$work/esp/loader/entries"
cp "$bootefi" "$work/esp/EFI/BOOT/BOOTX64.EFI"
cp "$work/cache/vmlinuz-lts" "$work/cache/initramfs-lts" "$work/cache/modloop-lts" "$work/esp/EFI/vbaz/"
cat > "$work/esp/loader/loader.conf" <<EOF
default vbaz-a.conf
timeout 3
console-mode keep
EOF
for slot in a b; do
    upper=$(printf %s "$slot" | tr a-z A-Z)
    cat > "$work/esp/loader/entries/vbaz-$slot.conf" <<EOF
title v-BAZ Alpine slot $upper
linux /EFI/vbaz/vmlinuz-lts
initrd /EFI/vbaz/initramfs-lts
options root=LABEL=VBAZ_ROOT_$upper rw rootfstype=ext4 modules=sd-mod,usb-storage,ext4 console=tty0 console=ttyS0,115200
EOF
done
sync
cleanup
trap - EXIT HUP INT TERM
echo "Alpine $version staged in root slots A/B and ESP"
