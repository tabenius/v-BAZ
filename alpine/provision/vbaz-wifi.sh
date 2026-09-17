#!/bin/sh
# v-BAZ :: Wi-Fi support (sourced by vbaz-provision.sh)
#
# Two things happen here:
#   1. ensure_wifi()  - a BEST-EFFORT attempt to associate Wi-Fi in the in-RAM
#      installer so the package install can run without Ethernet. This only
#      works if wpa_supplicant + the driver + firmware are already present in
#      the RAM environment, which the minimal Alpine netboot usually is NOT -
#      so for the first install you'll typically still need a temporary wired
#      link (USB phone tether or a USB-Ethernet dongle). See docs/WIFI.md.
#   2. setup_wifi()   - configures the INSTALLED host to use Wi-Fi natively
#      (wpa_supplicant + firmware + credentials + wlan0/dhcp), so after the
#      one-time wired install the machine connects over Wi-Fi on its own.
#
# The passphrase is provided transiently (etc/vbaz/secret.wifi); the persisted
# wpa_supplicant.conf stores only the hashed PSK, and the plaintext is shredded.

# Best-effort Wi-Fi bring-up in the RAM installer. Returns 0 if a default route
# comes up, non-zero otherwise. Never fatal.
ensure_wifi() {
    [ -n "${VBAZ_WIFI_SSID:-}" ] || return 1
    command -v wpa_supplicant >/dev/null 2>&1 || { log "Wi-Fi: wpa_supplicant not in the netboot env (expected); use a wired link for the install"; return 1; }
    wl=$(ls /sys/class/net 2>/dev/null | grep '^wl' | head -n1)
    [ -n "$wl" ] || { log "Wi-Fi: no wireless interface found (driver/firmware missing in netboot env)"; return 1; }
    log "Wi-Fi: attempting to associate $wl with $VBAZ_WIFI_SSID"
    psk=""; [ -f /etc/vbaz/secret.wifi ] && psk=$(cat /etc/vbaz/secret.wifi)
    conf=/tmp/vbaz-wpa.conf
    { echo "ctrl_interface=/run/wpa_supplicant"; [ -n "${VBAZ_WIFI_COUNTRY:-}" ] && echo "country=${VBAZ_WIFI_COUNTRY}"; } > "$conf"
    if [ -n "$psk" ]; then
        wpa_passphrase "$VBAZ_WIFI_SSID" "$psk" 2>/dev/null | grep -v '#psk=' >> "$conf" \
            || printf 'network={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$VBAZ_WIFI_SSID" "$psk" >> "$conf"
    else
        printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$VBAZ_WIFI_SSID" >> "$conf"
    fi
    ip link set "$wl" up 2>/dev/null
    wpa_supplicant -B -i "$wl" -c "$conf" 2>/dev/null || return 1
    udhcpc -i "$wl" -n -q 2>/dev/null || return 1
    ip route | grep -q default
}

# Configure Wi-Fi on the installed system (runs during the install phase, so it
# needs the temporary connectivity to apk-add the packages).
setup_wifi() {
    set +e
    [ -n "${VBAZ_WIFI_SSID:-}" ] || { log "no Wi-Fi SSID configured; skipping installed-host Wi-Fi"; return 0; }
    log "configuring Wi-Fi on the installed host (SSID: $VBAZ_WIFI_SSID)"

    chroot "$MNT" /sbin/apk add --no-cache wpa_supplicant wireless-regdb iw "${VBAZ_WIFI_FIRMWARE:-linux-firmware}" >/dev/null 2>&1 \
        || log "  WARN: Wi-Fi packages failed to install (was there connectivity during install?)"

    mkdir -p "$MNT/etc/wpa_supplicant"
    conf="$MNT/etc/wpa_supplicant/wpa_supplicant.conf"
    {
        echo "ctrl_interface=/run/wpa_supplicant"
        echo "update_config=1"
        [ -n "${VBAZ_WIFI_COUNTRY:-}" ] && echo "country=${VBAZ_WIFI_COUNTRY}"
    } > "$conf"

    psk=""; [ -f /etc/vbaz/secret.wifi ] && psk=$(cat /etc/vbaz/secret.wifi)
    if [ -n "$psk" ]; then
        # Store only the hashed PSK (wpa_passphrase emits the plaintext as a
        # #psk= comment, which we strip), then shred the plaintext.
        chroot "$MNT" wpa_passphrase "$VBAZ_WIFI_SSID" "$psk" 2>/dev/null | grep -v '#psk=' >> "$conf" \
            || printf 'network={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$VBAZ_WIFI_SSID" "$psk" >> "$conf"
        shred -u /etc/vbaz/secret.wifi 2>/dev/null || rm -f /etc/vbaz/secret.wifi
        log "  Wi-Fi PSK stored as a hash; plaintext shredded"
    else
        printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$VBAZ_WIFI_SSID" >> "$conf"
        log "  open network configured (no PSK)"
    fi
    chmod 600 "$conf"

    if ! grep -q '^auto wlan0' "$MNT/etc/network/interfaces" 2>/dev/null; then
        cat >> "$MNT/etc/network/interfaces" <<'EOF'

auto wlan0
iface wlan0 inet dhcp
EOF
    fi
    chroot "$MNT" rc-update add wpa_supplicant boot 2>/dev/null || true
    log "  installed host will connect to $VBAZ_WIFI_SSID over wlan0"
}
