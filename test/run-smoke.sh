#!/bin/sh
# v-BAZ :: boot the test disk under QEMU + OVMF and assert the provisioner runs.
#
# Boots the image built by build-test-disk.sh through a virtual UEFI firmware,
# captures the serial console, and checks for the provisioner's success marker.
# The guest reboots when provisioning finishes; -no-reboot makes QEMU exit
# there, so a clean run ends by itself.
#
# Prereqs: qemu-system-x86_64 and OVMF firmware. On Alpine:
#            apk add qemu-system-x86_64 ovmf
#          Networking (user-mode) is required for the in-guest apk install.
#
# Usage: run-smoke.sh [--disk IMG] [--timeout SEC] [--mem MB] [--smp N] [--gui]
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DISK="$REPO/test/vbaz-test.img"
DISK2=""
TIMEOUT=1800
MEM=4096
SMP=2
GUI=0
VERBOSE=0
RUNLOG="$REPO/test/run-smoke.log"

while [ $# -gt 0 ]; do
    case "$1" in
        --disk)    DISK="$2"; shift 2 ;;
        --disk2)   DISK2="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --mem)     MEM="$2"; shift 2 ;;
        --smp)     SMP="$2"; shift 2 ;;
        --gui)     GUI=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Mirror this runner's own output to a log (POSIX FIFO, no bashisms).
if command -v mkfifo >/dev/null 2>&1; then
    _fifo="${TMPDIR:-/tmp}/vbaz-runlog.$$"
    if mkfifo "$_fifo" 2>/dev/null; then
        tee -a "$RUNLOG" < "$_fifo" & _teepid=$!
        exec > "$_fifo" 2>&1
        trap 'rm -f "$_fifo"; wait "$_teepid" 2>/dev/null' EXIT
    fi
fi
[ "$VERBOSE" = 1 ] && set -x
echo "=== run-smoke $(date) (log: $RUNLOG) ==="

command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "qemu-system-x86_64 not found" >&2; exit 1; }
[ -f "$DISK" ] || { echo "disk image not found: $DISK (run build-test-disk.sh first)" >&2; exit 1; }
[ -z "$DISK2" ] || [ -f "$DISK2" ] || { echo "second disk not found: $DISK2" >&2; exit 1; }

# Locate OVMF firmware (code + writable vars copy).
ovmf_code=""
for p in /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
         /usr/share/ovmf/OVMF.fd /usr/share/edk2/x64/OVMF_CODE.fd \
         /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/qemu/edk2-x86_64-code.fd; do
    [ -f "$p" ] && { ovmf_code="$p"; break; }
done
[ -n "$ovmf_code" ] || { echo "OVMF firmware not found - install the 'ovmf'/'edk2-ovmf' package" >&2; exit 1; }
ovmf_vars_src=""
for p in /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd \
         /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
         /usr/share/qemu/edk2-i386-vars.fd; do
    [ -f "$p" ] && { ovmf_vars_src="$p"; break; }
done

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
log="$work/serial.log"
[ -n "$ovmf_vars_src" ] && cp "$ovmf_vars_src" "$work/OVMF_VARS.fd"

accel=tcg
[ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ] && accel=kvm
echo "OVMF: $ovmf_code   accel: $accel   disk: $DISK${DISK2:+   disk2: $DISK2}"
set -- \
    -machine q35,accel=$accel -cpu max -smp "$SMP" -m "$MEM" \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$ovmf_code" \
    -drive file="$DISK",format=raw,if=virtio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -no-reboot
[ -n "$DISK2" ] && set -- "$@" -drive file="$DISK2",format=raw,if=virtio
[ -f "$work/OVMF_VARS.fd" ] && set -- "$@" -drive if=pflash,format=raw,unit=1,file="$work/OVMF_VARS.fd"
if [ "$GUI" = 1 ]; then
    set -- "$@" -serial "file:$log"
else
    set -- "$@" -display none -serial "file:$log"
fi

echo "booting (timeout ${TIMEOUT}s); serial -> $log"
qemu-system-x86_64 "$@" &
qpid=$!

# Watch the serial log for success / failure markers or timeout.
ok='vbaz: provisioning finished OK'
fin='DONE. Rebooting into the installed'
rc=2
elapsed=0
while kill -0 "$qpid" 2>/dev/null; do
    if grep -qF "$ok" "$log" 2>/dev/null || grep -qF "$fin" "$log" 2>/dev/null; then
        echo "PASS: provisioner completed."; rc=0; break
    fi
    # Any of these mean the provisioner gave up.
    if grep -qEe 'provisioning FAILED|\[vbaz\]\[FATAL\]|provisioner ABORTED' "$log" 2>/dev/null; then
        echo "FAIL: provisioner reported failure."; rc=1; break
    fi
    if [ "$elapsed" -ge "$TIMEOUT" ]; then echo "FAIL: timeout after ${TIMEOUT}s."; rc=3; break; fi
    sleep 5; elapsed=$((elapsed + 5))
done
kill "$qpid" 2>/dev/null || true
wait "$qpid" 2>/dev/null || true

echo "----- last 30 serial lines -----"
tail -n 30 "$log" 2>/dev/null || true
cp "$log" "$REPO/test/last-serial.log" 2>/dev/null || true
echo "(full serial saved to test/last-serial.log)"
exit "$rc"
