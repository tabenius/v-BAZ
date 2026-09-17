#!/bin/sh
# v-BAZ :: Secure Boot kernel signing (sourced by vbaz-provision.sh)
#
# The Windows installer already signed the *installer* kernel and rEFInd with
# the MOK. Here we sign the *installed* kernel with the same MOK so it loads
# under Secure Boot, persist the key on the ext4 root (0600) for re-signing on
# future kernel upgrades, and shred the transient key material off the ESP.
#
# Must run BEFORE finalize_boot (which copies the installed kernel to the ESP).

sign_kernel() {
    set +e  # best-effort phase: signing issues must not abort the install
    [ "${VBAZ_SECUREBOOT:-0}" = "1" ] || { log "Secure Boot signing disabled; skipping"; return 0; }
    mok=/etc/vbaz/mok
    if [ ! -f "$mok/vbaz-mok.pfx" ]; then
        log "WARN: Secure Boot on but no MOK key in overlay; installed kernel will NOT be signed"
        return 0
    fi

    log "signing the installed kernel with the v-BAZ MOK"
    apk add --no-cache openssl sbsigntool >/dev/null 2>&1 \
        || { log "WARN: could not install sbsigntool/openssl in installer env; skipping signing"; return 0; }

    pass=$(cat "$mok/vbaz-mok.pfx.pass" 2>/dev/null)
    key=/tmp/vbaz-mok.key
    crt=/tmp/vbaz-mok.crt
    openssl pkcs12 -in "$mok/vbaz-mok.pfx" -nocerts -nodes -passin "pass:$pass" -out "$key" 2>/dev/null \
        || { log "WARN: could not extract MOK key"; return 0; }
    openssl pkcs12 -in "$mok/vbaz-mok.pfx" -clcerts -nokeys -passin "pass:$pass" -out "$crt" 2>/dev/null \
        || { log "WARN: could not extract MOK cert"; return 0; }

    for k in "$MNT"/boot/vmlinuz-*; do
        [ -f "$k" ] || continue
        # sbsign is idempotent-ish: signing an already-signed file replaces it.
        sbsign --key "$key" --cert "$crt" --output "$k" "$k" >/dev/null 2>&1 \
            && log "  signed $(basename "$k")" \
            || log "  WARN: failed to sign $(basename "$k")"
    done

    # Persist key+cert on the installed root (root-only) for future upgrades,
    # plus a helper + sbsigntool inside the installed system.
    instmok="$MNT/etc/vbaz/mok"
    mkdir -p "$instmok"
    cp "$key" "$instmok/mok.key"; cp "$crt" "$instmok/mok.crt"
    cp "$mok/vbaz-mok.cer" "$instmok/vbaz-mok.cer" 2>/dev/null || true
    chmod 0700 "$instmok"; chmod 0600 "$instmok"/* 2>/dev/null || true
    chroot "$MNT" /sbin/apk add --no-cache sbsigntool >/dev/null 2>&1 || true
    _write_resign_helper

    # Shred the transient PFX/password (RAM overlay copy). The ESP copy lives
    # inside vbaz.apkovl.tar.gz, which finalize_boot deletes from the ESP.
    shred -u "$mok/vbaz-mok.pfx" "$mok/vbaz-mok.pfx.pass" 2>/dev/null \
        || rm -f "$mok/vbaz-mok.pfx" "$mok/vbaz-mok.pfx.pass"
    rm -f "$key" "$crt"
    log "MOK key persisted to /etc/vbaz/mok (root-only); ESP key material shredded"
}

# A helper the operator runs after a kernel upgrade to re-sign + republish the
# kernel to the ESP so Secure Boot keeps working.
_write_resign_helper() {
    cat > "$MNT/usr/local/sbin/vbaz-sign-kernel" <<'SH'
#!/bin/sh
# Re-sign the current kernel with the v-BAZ MOK and copy it to the ESP.
set -eu
[ -f /etc/vbaz/vbaz.env ] && . /etc/vbaz/vbaz.env
MOK=/etc/vbaz/mok
ESPSUB="${VBAZ_ESPSUBDIR:-vbaz}"
k=$(ls /boot/vmlinuz-* 2>/dev/null | head -n1)
i=$(ls /boot/initramfs-* 2>/dev/null | head -n1)
[ -n "$k" ] || { echo "no kernel found"; exit 1; }
sbsign --key "$MOK/mok.key" --cert "$MOK/mok.crt" --output "$k" "$k"
esp=$(lsblk -rno NAME,PARTTYPE -p | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print $1;exit}')
m=$(mktemp -d); mount "$esp" "$m"
cp "$k" "$m/EFI/$ESPSUB/vmlinuz-lts-installed"
[ -n "$i" ] && cp "$i" "$m/EFI/$ESPSUB/initramfs-lts-installed"
sync; umount "$m"; rmdir "$m"
echo "re-signed and republished $k to the ESP"
SH
    chmod 0755 "$MNT/usr/local/sbin/vbaz-sign-kernel"
}
