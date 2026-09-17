#!/bin/sh
# v-BAZ :: device-mapper thin-pool on ZFS zvols (sourced by vbaz-provision.sh)
#
# containerd's devmapper snapshotter (used by the kata-fc / Firecracker Kata
# backend) needs a dm-thin pool. We back it with two sparse ZFS zvols:
#   <pool>/thinpool       -> data device
#   <pool>/thinpool-meta  -> metadata device
# The zvols persist; the dm-thin device is volatile, so an OpenRC service
# re-creates it from the zvols on every boot (before containerd). The metadata
# device is zeroed only on FIRST creation - never again, or the pool is lost.

setup_thinpool() {
    set +e  # best-effort phase
    [ "${VBAZ_KATA_DEVMAPPER:-0}" = "1" ] || { log "kata devmapper disabled; skipping thin-pool"; return 0; }
    [ "${VBAZ_ZFS_ENABLE:-0}" = "1" ] || { log "thin-pool needs ZFS; skipping"; return 0; }
    echo "$VBAZ_PACKAGE_SETS" | grep -qw kata || { log "kata set absent; skipping thin-pool"; return 0; }

    log "wiring the kata-fc devmapper thin-pool (ZFS zvols)"
    chroot "$MNT" /sbin/apk add --no-cache device-mapper thin-provisioning-tools >/dev/null 2>&1 \
        || log "  WARN: device-mapper/thin-provisioning-tools apk failed"
    echo 'dm-thin-pool' >> "$MNT/etc/modules-load.d/dm-thin.conf" 2>/dev/null || true
    mkdir -p "$MNT/var/lib/containerd/devmapper"

    _write_thinpool_service
    log "thin-pool '${VBAZ_THINPOOL_NAME}' will be created on first boot"
}

_write_thinpool_service() {
    cat > "$MNT/etc/init.d/vbaz-thinpool" <<'INITD'
#!/sbin/openrc-run
description="v-BAZ device-mapper thin-pool on ZFS zvols (for kata-fc)"

depend() {
    after vbaz-storage zfs-mount
    before containerd
    need localmount
}

start() {
    [ -f /etc/vbaz/vbaz.env ] && . /etc/vbaz/vbaz.env
    [ "${VBAZ_KATA_DEVMAPPER:-0}" = "1" ] || return 0
    [ "${VBAZ_ZFS_ENABLE:-0}" = "1" ] || return 0

    pool="${VBAZ_ZFS_POOL}"
    name="${VBAZ_THINPOOL_NAME:-vbaz-thinpool}"
    datavol="${pool}/thinpool"
    metavol="${pool}/thinpool-meta"
    datadev="/dev/zvol/${datavol}"
    metadev="/dev/zvol/${metavol}"
    marker="/var/lib/vbaz/thinpool-initialized"

    ebegin "Ensuring dm thin-pool ${name}"
    modprobe dm-thin-pool 2>/dev/null

    zpool list "${pool}" >/dev/null 2>&1 || { ewarn "pool ${pool} not present"; eend 0; return 0; }

    fresh=0
    if ! zfs list "${datavol}" >/dev/null 2>&1; then
        einfo "creating data zvol ${datavol} (${VBAZ_THINPOOL_DATASIZE:-100G}, sparse)"
        zfs create -s -V "${VBAZ_THINPOOL_DATASIZE:-100G}" -o volmode=dev "${datavol}" || { eend 1; return 1; }
        fresh=1
    fi
    if ! zfs list "${metavol}" >/dev/null 2>&1; then
        einfo "creating metadata zvol ${metavol} (${VBAZ_THINPOOL_METASIZE:-1G}, sparse)"
        zfs create -s -V "${VBAZ_THINPOOL_METASIZE:-1G}" -o volmode=dev "${metavol}" || { eend 1; return 1; }
        fresh=1
    fi

    # Wait for the zvol device nodes.
    i=0; while [ ! -e "$datadev" ] || [ ! -e "$metadev" ]; do
        i=$((i+1)); [ "$i" -gt 50 ] && { ewarn "zvol device nodes missing"; eend 1; return 1; }
        sleep 0.2
    done

    if dmsetup info "$name" >/dev/null 2>&1; then
        eend 0; return 0   # already active this boot
    fi

    # Zero the metadata head ONLY when the pool is first created, else reuse.
    if [ ! -f "$marker" ] || [ "$fresh" = "1" ]; then
        einfo "initialising thin-pool metadata (first time)"
        dd if=/dev/zero of="$metadev" bs=4096 count=1 conv=fsync 2>/dev/null
    fi

    sectors=$(blockdev --getsz "$datadev" 2>/dev/null)
    [ -n "$sectors" ] || { ewarn "cannot size $datadev"; eend 1; return 1; }
    # data_block_size=128 sectors (64KiB); low_water_mark=32768 blocks.
    if dmsetup create "$name" --table "0 $sectors thin-pool $metadev $datadev 128 32768"; then
        mkdir -p /var/lib/vbaz && touch "$marker"
        eend 0
    else
        eend 1
    fi
}

stop() {
    [ -f /etc/vbaz/vbaz.env ] && . /etc/vbaz/vbaz.env
    name="${VBAZ_THINPOOL_NAME:-vbaz-thinpool}"
    ebegin "Removing dm thin-pool ${name}"
    dmsetup remove "$name" 2>/dev/null
    eend 0
}
INITD
    chmod +x "$MNT/etc/init.d/vbaz-thinpool"
    chroot "$MNT" rc-update add vbaz-thinpool boot 2>/dev/null || true
}
