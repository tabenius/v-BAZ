#!/bin/sh
set -eu
image=${1:?usage: verify-ovmf.sh IMAGE.raw [TIMEOUT]}
limit=${2:-180}
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qemu-system-x86_64 is required" >&2; exit 2; }
code=""; vars=""
for p in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [ -f "$p" ] && { code=$p; break; }; done
for p in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do [ -f "$p" ] && { vars=$p; break; }; done
[ -n "$code" ] && [ -n "$vars" ] || { echo "OVMF firmware not found" >&2; exit 2; }
work=$(mktemp -d); cp "$vars" "$work/vars.fd"; log="$work/serial.log"
cleanup(){ [ -z "${pid:-}" ] || kill "$pid" 2>/dev/null || true; rm -rf "$work"; }; trap cleanup EXIT HUP INT TERM
qemu-system-x86_64 -machine q35,accel=tcg -cpu max -smp 2 -m 1024 -no-reboot -display none \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$code" -drive if=pflash,format=raw,unit=1,file="$work/vars.fd" \
  -drive file="$image",format=raw,if=virtio -serial "file:$log" & pid=$!
elapsed=0
while kill -0 "$pid" 2>/dev/null; do
    if grep -q 'vbaz-portable: slot A booted' "$log" 2>/dev/null; then echo "OVMF boot verified: slot A"; exit 0; fi
    [ "$elapsed" -lt "$limit" ] || { tail -80 "$log" >&2 || true; echo "OVMF boot timed out" >&2; exit 1; }
    sleep 3; elapsed=$((elapsed+3))
done
tail -80 "$log" >&2 || true; echo "QEMU exited before boot marker" >&2; exit 1
