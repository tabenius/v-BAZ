#!/bin/sh
# v-BAZ :: static wiring checks (no QEMU, runs anywhere)
#
# Catches the bug class most likely in a two-sided installer: things that must
# agree between the Windows side (PowerShell) and the Alpine side (shell) but
# are declared in different files. Namely:
#   1. shell syntax (sh -n) + shellcheck if present
#   2. GPT type GUIDs consistent between config and the provisioner
#   3. every VBAZ_* env var the shell READS is WRITTEN by the apkovl builder
#   4. every @@PLACEHOLDER@@ in refind.conf.template is substituted by Boot.ps1
#
# Exit non-zero on any failure. Intended for local runs and CI.
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO"

fail=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; }
hdr()  { printf '\n\033[36m==>\033[0m %s\n' "$1"; }

APKOVL=windows/lib/Apkovl.ps1
CONFIG=windows/vbaz.config.psd1
BOOT=windows/lib/Boot.ps1
TEMPLATE=refind/refind.conf.template
SHELLS="alpine/provision/vbaz-provision.sh alpine/provision/vbaz-storage.sh \
        alpine/provision/vbaz-runtimes.sh alpine/provision/vbaz-rebekah.sh \
        alpine/provision/vbaz-guest.sh \
        alpine/provision/vbaz-secureboot.sh \
        alpine/provision/vbaz-thinpool.sh alpine/overlay/etc/local.d/vbaz-provision.start \
        alpine/provision/vbaz-wifi.sh alpine/provision/vbaz-offline.sh \
        test/check-wiring.sh test/build-apkovl.sh test/build-test-disk.sh test/run-smoke.sh \
        tools/build-offline-bundle.sh tools/build-artifact-cache.sh \
        tools/usb/layout.sh tools/usb/validate-config.sh tools/usb/build-image.sh \
        tools/usb/convert-vhdx.sh tools/usb/populate-host.sh tools/usb/verify-ovmf.sh \
        tools/usb/prepare-kali-persistence.sh tools/usb/populate-kali-guest.sh \
        tools/usb/vbaz-kali-run.sh tools/usb/vbaz-kali.openrc \
        test/test-usb-layout.sh test/test-kali-persistence.sh"

# --- 1. shell syntax -------------------------------------------------------
hdr "shell syntax (sh -n)"
for f in $SHELLS; do
    [ -f "$f" ] || continue
    if sh -n "$f" 2>/dev/null; then pass "$f"; else bad "$f (sh -n)"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
    hdr "shellcheck"
    for f in $SHELLS; do
        [ -f "$f" ] || continue
        if shellcheck -S warning -e SC1090,SC1091,SC2086,SC2016 "$f" >/dev/null 2>&1; then
            pass "$f"; else warn "$f (shellcheck findings; run manually)"; fi
    done
else
    warn "shellcheck not installed (skipping deeper lint)"
fi

# --- 2. GPT type GUIDs -----------------------------------------------------
hdr "GPT type GUID consistency"
cfg_guid() { grep -iE "^\s*$1\s*=" "$CONFIG" | grep -oiE "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}" | head -n1 | tr 'A-Z' 'a-z'; }
ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
SWAP_CFG=$(cfg_guid SwapPartitionType)
ZFS_CFG=$(cfg_guid ZfsPartitionType)
ROOT_CFG=$(cfg_guid RootPartitionType)

# Swap GUID is hardcoded in the provisioner (swap + zram detection) - must match config.
SWAP_HARD=$(grep -rhoiE '0657fd6d-a4ab-43c4-84e5-0933c84b4f4f' alpine/provision | head -n1 | tr 'A-Z' 'a-z')
[ -n "$SWAP_CFG" ] && pass "config SwapPartitionType present ($SWAP_CFG)" || bad "SwapPartitionType missing in config"
if [ -n "$SWAP_HARD" ] && [ "$SWAP_HARD" = "$SWAP_CFG" ]; then pass "swap GUID config==provisioner"; else bad "swap GUID mismatch: cfg=$SWAP_CFG provisioner=$SWAP_HARD"; fi

# ESP GUID hardcoded in find_esp + the resign helper - must all be the standard ESP GUID.
espn=$(grep -rhoiE 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' alpine/provision | tr 'A-Z' 'a-z' | sort -u | wc -l | tr -d ' ')
espbad=$(grep -rhoiE 'c12a7328-[0-9a-f-]+' alpine/provision | tr 'A-Z' 'a-z' | grep -v "^$ESP_GUID$" | sort -u || true)
if [ -z "$espbad" ]; then pass "ESP GUID uses the standard value everywhere"; else bad "non-standard ESP GUID variant(s): $espbad"; fi

for n in ROOT_CFG ZFS_CFG; do
    eval "v=\$$n"
    if printf '%s' "$v" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        pass "$n is a valid GUID ($v)"; else bad "$n invalid/missing: '$v'"; fi
done

# --- 3. env var cross-check ------------------------------------------------
hdr "env vars: shell READS must be apkovl WRITES"
# Written by the apkovl builder (lines like  "VBAZ_FOO='...'" ).
written=$(grep -oE "VBAZ_[A-Z0-9_]+='" "$APKOVL" | sed "s/='$//" | sort -u)
# Read by the Alpine shell: only $-prefixed references ($VBAZ_X / ${VBAZ_X}),
# not bare label literals like "VBAZ_ROOT" (a filesystem label default).
readvars=$(grep -rhoE '\$\{?VBAZ_[A-Z0-9_]+' alpine/provision alpine/overlay | sed 's/^\${*//' | sort -u)

miss=0
for r in $readvars; do
    if printf '%s\n' "$written" | grep -qx "$r"; then :; else
        bad "read but never written by apkovl: \$$r"; miss=1
    fi
done
[ "$miss" -eq 0 ] && pass "every VBAZ_* read by the shell is written by the apkovl builder"

# Informational: written but never read (dead / documentation-only).
for w in $written; do
    printf '%s\n' "$readvars" | grep -qx "$w" || warn "written but never read: \$$w"
done

# --- 4. refind.conf placeholders ------------------------------------------
hdr "refind.conf template placeholders are all substituted"
tokens=$(grep -oE '@@[A-Z_]+@@' "$TEMPLATE" | sort -u)
subs=$(grep -oE "@@[A-Z_]+@@" "$BOOT" | sort -u)
tmiss=0
for t in $tokens; do
    if printf '%s\n' "$subs" | grep -qx "$t"; then :; else bad "placeholder $t never substituted in Boot.ps1"; tmiss=1; fi
done
[ "$tmiss" -eq 0 ] && pass "all $(printf '%s\n' "$tokens" | grep -c .) template placeholders are substituted"

# --- 4b. busybox portability (Alpine scripts run under busybox sed/grep) ---
hdr "busybox portability: no GNU-only regex (\\s \\w \\b) in provisioner"
# grep -rn prints file:line:content; drop comment lines before judging.
badre=$(grep -rn '\\[swb]' alpine/provision alpine/overlay 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' || true)
if [ -n "$badre" ]; then
    bad "GNU-only regex escapes found (busybox sed/grep will not match them):"
    printf '%s\n' "$badre" | sed 's/^/      /'
else
    pass "no GNU-only \\s/\\w/\\b escapes in Alpine scripts"
fi

# --- 5. package sets referenced exist -------------------------------------
hdr "package sets"
sets=$(grep -oE '^set:[a-z]+' alpine/provision/packages.list | sed 's/set://' | sort -u)
for s in base virt firecracker; do
    printf '%s\n' "$sets" | grep -qx "$s" && pass "packages.list defines set '$s'" || bad "packages.list missing set '$s'"
done

hdr "portable USB layout"
if command -v jq >/dev/null 2>&1; then
    if sh test/test-usb-layout.sh >/dev/null; then pass "USB configuration and layout"; else bad "USB configuration or layout"; fi
else
    warn "jq not installed (skipping USB configuration test)"
fi

# --- verdict ---------------------------------------------------------------
printf '\n'
if [ "$fail" -eq 0 ]; then printf '\033[32mALL WIRING CHECKS PASSED\033[0m\n'; else printf '\033[31mWIRING CHECKS FAILED\033[0m\n'; fi
exit "$fail"
