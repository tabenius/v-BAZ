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

source_iso="$work/source.iso"
printf 'synthetic Kali ISO fixture\n' > "$source_iso"
digest=$(sha256sum "$source_iso" | awk '{print $1}')
media_root="$work"
sh "$repo/tools/usb/stage-kali-iso.sh" "$media_root" "$source_iso" "$digest" >/dev/null
cmp "$source_iso" "$media_root/guests/kali/kali-live.iso"
grep -q "$digest  kali-live.iso" "$media_root/guests/kali/kali-live.iso.sha256"
grep -q '"schema": "vbaz.kali-media.v1"' "$media_root/guests/kali/media.json"
grep -q "\"sha256\": \"$digest\"" "$media_root/guests/kali/media.json"
mkdir -p "$work/bin"
cat > "$work/bin/qemu-system-x86_64" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$VBAZ_QEMU_ARGS"
EOF
chmod +x "$work/bin/qemu-system-x86_64"
VBAZ_KALI_DIR="$media_root/guests/kali" VBAZ_QEMU_ARGS="$work/qemu.args" \
    PATH="$work/bin:$PATH" sh "$repo/tools/usb/vbaz-kali-run.sh" >/dev/null 2>&1
grep -q 'q35,accel=tcg' "$work/qemu.args"
grep -q 'hostfwd=tcp:127.0.0.1:2222-:22' "$work/qemu.args"
grep -q '127.0.0.1:0' "$work/qemu.args"
grep -q "file=$media_root/guests/kali/persistence.raw,format=raw,if=virtio,cache=none" "$work/qemu.args"
if sh "$repo/tools/usb/stage-kali-iso.sh" "$media_root" "$source_iso" "$digest" >/dev/null 2>&1; then
    echo "existing Kali media was overwritten" >&2
    exit 1
fi
bad_root="$work/bad-media"
mkdir -p "$bad_root"
if sh "$repo/tools/usb/stage-kali-iso.sh" "$bad_root" "$source_iso" "$(printf '0%.0s' $(seq 1 64))" >/dev/null 2>&1; then
    echo "bad Kali ISO checksum was accepted" >&2
    exit 1
fi
[ ! -e "$bad_root/guests/kali/kali-live.iso" ]
echo "Kali media staging tests passed"
