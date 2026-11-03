#!/bin/sh
# Launch the checksum-pinned Kali Live guest with its separate persistence disk.
set -eu
guest_dir=${VBAZ_KALI_DIR:-/var/lib/vbaz/guests/kali}
iso="$guest_dir/kali-live.iso"
persistence="$guest_dir/persistence.raw"
checksum="$guest_dir/kali-live.iso.sha256"

[ -r "$iso" ] || { echo "vbaz-kali: missing $iso" >&2; exit 1; }
[ -r "$persistence" ] || { echo "vbaz-kali: missing $persistence" >&2; exit 1; }
[ -r "$checksum" ] || { echo "vbaz-kali: missing $checksum" >&2; exit 1; }
(cd "$guest_dir" && sha256sum -c "$(basename "$checksum")")

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    accel=kvm
    cpu=host
else
    accel=tcg
    cpu=max
    echo "vbaz-kali: /dev/kvm unavailable; using slower TCG emulation" >&2
fi

exec qemu-system-x86_64 \
    -name vbaz-kali \
    -machine "q35,accel=$accel" \
    -cpu "$cpu" -smp "${VBAZ_KALI_CPUS:-4}" -m "${VBAZ_KALI_MEMORY_MIB:-4096}" \
    -boot order=d,menu=on \
    -drive "file=$iso,media=cdrom,readonly=on" \
    -drive "file=$persistence,format=raw,if=virtio,cache=none" \
    -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 \
    -display none -vnc 127.0.0.1:0 \
    -serial file:/var/log/vbaz-kali-serial.log \
    -monitor unix:/run/vbaz-kali-monitor.sock,server,nowait
