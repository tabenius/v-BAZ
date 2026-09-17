#!/bin/sh
# v-BAZ :: ZFS guest storage pool (sourced by vbaz-provision.sh)
#
# Sets up ZFS in the INSTALLED system so that ALL guest state (VM disks,
# container/image data, microVM rootfs) lives on a pool on the large
# partition (e.g. D:), keeping the small host root lean.
#
# The pool is created on the installed system's FIRST real boot (by an OpenRC
# service we drop below) rather than in the RAM installer - that guarantees
# the zfs kernel module matches the running kernel exactly. Creating the pool
# DESTROYS the tagged partition's contents.

setup_storage() {
    set +e  # best-effort phase: a package/config hiccup must not abort the install
    [ "${VBAZ_ZFS_ENABLE:-0}" = "1" ] || { log "ZFS disabled; skipping guest pool"; return 0; }
    echo "$VBAZ_PACKAGE_SETS" | grep -qw zfs || { log "ZFS enabled but 'zfs' not in package sets; skipping"; return 0; }

    log "installing ZFS into the host and wiring the guest pool"
    chroot "$MNT" /sbin/apk add --no-cache zfs "zfs-$VBAZ_FLAVOR" >/dev/null 2>&1 \
        || chroot "$MNT" /sbin/apk add --no-cache zfs zfs-lts >/dev/null 2>&1 \
        || { log "WARN: zfs packages failed to install; pool not configured"; return 0; }

    # Module autoloads; ZFS OpenRC services import/mount at boot.
    echo zfs > "$MNT/etc/modules-load.d/zfs.conf" 2>/dev/null || echo zfs >> "$MNT/etc/modules"
    for svc in zfs-import zfs-mount zfs-zed; do
        chroot "$MNT" rc-update add "$svc" boot 2>/dev/null || \
        chroot "$MNT" rc-update add "$svc" default 2>/dev/null || true
    done

    # Ensure the installed system can read our pool config.
    mkdir -p "$MNT/etc/vbaz"
    cp /etc/vbaz/vbaz.env "$MNT/etc/vbaz/vbaz.env" 2>/dev/null || true

    _write_storage_service
    log "ZFS pool '$VBAZ_ZFS_POOL' will be created/imported on first boot"
}

# OpenRC service that creates-or-imports the pool and lays out datasets before
# any guest runtime starts. Idempotent.
_write_storage_service() {
    cat > "$MNT/etc/init.d/vbaz-storage" <<'INITD'
#!/sbin/openrc-run
description="v-BAZ ZFS guest pool (create/import + datasets)"

depend() {
    after zfs-import zfs-mount localmount
    before docker containerd libvirtd firecracker
    need localmount
}

start() {
    [ -f /etc/vbaz/vbaz.env ] && . /etc/vbaz/vbaz.env
    [ "${VBAZ_ZFS_ENABLE:-0}" = "1" ] || return 0
    ebegin "Ensuring ZFS pool ${VBAZ_ZFS_POOL}"
    modprobe zfs 2>/dev/null

    if ! zpool list "${VBAZ_ZFS_POOL}" >/dev/null 2>&1; then
        if ! zpool import -N "${VBAZ_ZFS_POOL}" >/dev/null 2>&1; then
            dev=$(lsblk -rno NAME,PARTTYPE -p 2>/dev/null \
                  | awk -v t="${VBAZ_ZFS_TYPE}" 'tolower($2)==tolower(t){print $1; exit}')
            if [ -n "$dev" ]; then
                einfo "Creating pool ${VBAZ_ZFS_POOL} on $dev (destroys its contents)"
                zpool create -f -o ashift=12 -o autotrim=on \
                    -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
                    -O mountpoint=none "${VBAZ_ZFS_POOL}" "$dev" || { eend 1; return 1; }
            else
                ewarn "No ZFS-tagged partition found; skipping pool"
                eend 0; return 0
            fi
        fi
    fi

    for ds in ${VBAZ_ZFS_DATASETS}; do
        zfs list "${VBAZ_ZFS_POOL}/$ds" >/dev/null 2>&1 || zfs create "${VBAZ_ZFS_POOL}/$ds"
    done

    _mp() { zfs list "${VBAZ_ZFS_POOL}/$1" >/dev/null 2>&1 && zfs set mountpoint="$2" "${VBAZ_ZFS_POOL}/$1" 2>/dev/null || true; }
    _mp vms         /var/lib/libvirt/images
    _mp docker      /var/lib/docker
    _mp firecracker /var/lib/vbaz/firecracker
    _mp kata        /var/lib/vbaz/kata
    _mp images      /var/lib/vbaz/images
    _mp iso         /var/lib/vbaz/iso
    zfs mount -a 2>/dev/null
    zpool set cachefile=/etc/zfs/zpool.cache "${VBAZ_ZFS_POOL}" 2>/dev/null || true
    eend 0
}
INITD
    chmod +x "$MNT/etc/init.d/vbaz-storage"
    chroot "$MNT" rc-update add vbaz-storage boot 2>/dev/null || true
}
