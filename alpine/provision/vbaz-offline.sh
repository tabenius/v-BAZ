#!/bin/sh
# v-BAZ :: offline first boot (sourced by vbaz-provision.sh)
#
# When VBAZ_OFFLINE=1 the whole install runs from a LOCAL apk repository staged
# on the ESP by the offline bundle (tools/build-offline-bundle.sh) - no network
# needed. Wi-Fi is then brought up from those local packages so the installed
# host is online afterwards, with no Ethernet and no tether.
#
# Relies on functions/vars from the main provisioner: log/die, find_esp,
# ESPMNT, MNT, MAIN, COMMUNITY, VBAZ_ESPSUBDIR, VBAZ_ARCH, VBAZ_MIRROR,
# VBAZ_BRANCH, VBAZ_WIFI_*.

_off_repo()  { echo "$ESPMNT/EFI/$VBAZ_ESPSUBDIR/apks"; }
_off_keys()  { echo "$ESPMNT/EFI/$VBAZ_ESPSUBDIR/apk-keys"; }

# Mount the ESP, point apk at the local repo, trust its key, expose modules.
offline_prepare() {
    log "offline mode: preparing local repository"
    espdev=$(find_esp) || die "offline: ESP not found"
    mkdir -p "$ESPMNT"
    mountpoint -q "$ESPMNT" || mount "$espdev" "$ESPMNT" || die "offline: cannot mount ESP ($espdev)"
    repo=$(_off_repo)
    [ -f "$repo/$VBAZ_ARCH/APKINDEX.tar.gz" ] \
        || die "offline: local repo missing ($repo/$VBAZ_ARCH/APKINDEX.tar.gz) - was -Offline staged?"
    mkdir -p /etc/apk/keys
    for k in "$(_off_keys)"/*.pub; do [ -f "$k" ] && cp "$k" /etc/apk/keys/ 2>/dev/null; done
    # The local repo becomes the only apk source (both slots point at it).
    MAIN="$repo"; COMMUNITY="$repo"
    offline_modloop
    log "offline: local repo $repo (arch $VBAZ_ARCH)"
}

# Make the full kernel module set available from the ESP-staged modloop, so
# Wi-Fi / ZFS drivers can load in the in-RAM installer (the netboot initramfs
# only carries a minimal set).
offline_modloop() {
    kver=$(uname -r)
    if [ -d "/lib/modules/$kver/kernel" ]; then return 0; fi
    ml="$ESPMNT/EFI/$VBAZ_ESPSUBDIR/modloop-lts"
    [ -f "$ml" ] || { log "offline: modloop not on ESP; some drivers may be unavailable"; return 1; }
    modprobe loop 2>/dev/null || true
    mkdir -p /.modloop
    mount -o loop,ro "$ml" /.modloop 2>/dev/null || { log "offline: could not mount modloop"; return 1; }
    if [ -d "/.modloop/modules/$kver" ]; then
        mkdir -p /lib/modules
        [ -e "/lib/modules/$kver" ] || ln -s "/.modloop/modules/$kver" "/lib/modules/$kver"
        depmod "$kver" 2>/dev/null || true
        log "offline: kernel modules available from local modloop"
    fi
}

# Install the Wi-Fi stack from the local repo and try to associate, so the
# rest of the (already-local) install proceeds and the host ends up online.
offline_wifi_up() {
    if [ -z "${VBAZ_WIFI_SSID:-}" ]; then
        log "offline: no Wi-Fi SSID set - installing from local repo only (set WifiSSID to get the host online)"
        return 1
    fi
    log "offline: installing Wi-Fi stack from the local repo"
    apk add --no-cache wpa_supplicant wireless-regdb iw "${VBAZ_WIFI_FIRMWARE:-linux-firmware}" >/dev/null 2>&1 \
        || { log "offline: Wi-Fi packages not in the local bundle"; return 1; }
    modprobe cfg80211 2>/dev/null || true
    modprobe mac80211 2>/dev/null || true
    command -v ensure_wifi >/dev/null 2>&1 && ensure_wifi
}

# Point the INSTALLED system's apk repos back at the online mirror so it can
# update later (over Wi-Fi). Called after the offline install completes.
offline_finalize_repos() {
    printf '%s\n%s\n' "$VBAZ_MIRROR/$VBAZ_BRANCH/main" "$VBAZ_MIRROR/$VBAZ_BRANCH/community" \
        > "$MNT/etc/apk/repositories" 2>/dev/null || true
}
