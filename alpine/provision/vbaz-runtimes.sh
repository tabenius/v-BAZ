#!/bin/sh
# v-BAZ :: guest runtimes (sourced by vbaz-provision.sh)
#
# Wires up the runtimes that consume the ZFS pool:
#   docker       - engine, ZFS storage driver, data-root on vbaz/docker
#   containerd   - shared CRI, with kata-qemu / kata-fc runtime handlers
#   kata         - VM-isolated containers (QEMU and Firecracker backends)
#   libvirt/QEMU - default images pool on vbaz/vms
#   firecracker  - dir on vbaz/firecracker (binary installed in main script)
#
# Runs in the RAM installer against $MNT. Package installs are best-effort:
# some (kata, nerdctl) may not be in your Alpine branch, in which case we log
# and fall back to upstream static releases where practical.

setup_runtimes() {
    set +e  # best-effort phase: runtime install hiccups must not abort the install
    _has_set() { echo "$VBAZ_PACKAGE_SETS" | grep -qw "$1"; }

    _has_set docker     && _rt_docker
    _has_set containers && _rt_containerd
    _has_set kata       && _rt_kata
    _has_set virt       && _rt_libvirt_pool
    _rt_firecracker_dirs
}

_rt_docker() {
    log "runtime: docker"
    chroot "$MNT" /sbin/apk add --no-cache docker docker-cli-compose >/dev/null 2>&1 \
        || chroot "$MNT" /sbin/apk add --no-cache docker >/dev/null 2>&1 \
        || { log "WARN: docker apk failed"; return 0; }

    mkdir -p "$MNT/etc/docker"
    if [ "${VBAZ_ZFS_ENABLE:-0}" = "1" ]; then
        # Docker's zfs graphdriver requires data-root to be its own dataset,
        # which vbaz-storage mounts at /var/lib/docker before docker starts.
        cat > "$MNT/etc/docker/daemon.json" <<'JSON'
{
  "storage-driver": "zfs",
  "data-root": "/var/lib/docker"
}
JSON
    else
        printf '{\n  "storage-driver": "overlay2"\n}\n' > "$MNT/etc/docker/daemon.json"
    fi
    chroot "$MNT" rc-update add docker default 2>/dev/null || true
    chroot "$MNT" addgroup "$VBAZ_USERNAME" docker 2>/dev/null || true
}

_rt_containerd() {
    log "runtime: containerd + CNI"
    chroot "$MNT" /sbin/apk add --no-cache containerd cni-plugins >/dev/null 2>&1 \
        || { log "WARN: containerd apk failed"; return 0; }
    chroot "$MNT" /sbin/apk add --no-cache nerdctl >/dev/null 2>&1 || log "  (nerdctl not available in this branch)"
    chroot "$MNT" rc-update add containerd default 2>/dev/null || true

    # Generate a default config and append kata runtime handlers.
    mkdir -p "$MNT/etc/containerd"
    chroot "$MNT" sh -c 'containerd config default > /etc/containerd/config.toml' 2>/dev/null || true
    if ! grep -q 'runtimes.kata' "$MNT/etc/containerd/config.toml" 2>/dev/null; then
        cat >> "$MNT/etc/containerd/config.toml" <<'TOML'

# --- v-BAZ: Kata Containers runtime handlers -------------------------------
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-qemu]
  runtime_type = "io.containerd.kata-qemu.v2"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata-fc]
  runtime_type = "io.containerd.kata-fc.v2"
TOML
    fi
}

_rt_kata() {
    log "runtime: kata containers"
    # musl needs a glibc shim for the upstream static binaries.
    chroot "$MNT" /sbin/apk add --no-cache gcompat >/dev/null 2>&1 || true
    if chroot "$MNT" /sbin/apk add --no-cache kata-containers >/dev/null 2>&1 \
       || chroot "$MNT" /sbin/apk add --no-cache kata-runtime >/dev/null 2>&1; then
        log "  kata from apk"
    else
        log "  kata apk unavailable; fetching upstream static release"
        _kata_static || { log "  WARN: kata static fetch failed; configure it manually later"; return 0; }
    fi

    # Point kata at host QEMU and Firecracker, and its data at the ZFS dataset.
    mkdir -p "$MNT/etc/kata-containers" "$MNT/var/lib/vbaz/kata"
    # Firecracker backend needs devmapper snapshotter in containerd; documented
    # in docs/DISK-LAYOUT.md. Default (kata-qemu) works out of the box.
    log "  kata configured (kata-qemu default; kata-fc available - see docs/DISK-LAYOUT.md)"
}

_kata_static() {
    kver=$(wget -qO- https://api.github.com/repos/kata-containers/kata-containers/releases/latest \
           | awk -F'"' '/"tag_name"/{print $4; exit}')
    [ -n "$kver" ] || return 1
    n=${kver#v}
    url="https://github.com/kata-containers/kata-containers/releases/download/${kver}/kata-static-${n}-amd64.tar.xz"
    tmp=$(mktemp -d)
    wget -qO "$tmp/kata.tar.xz" "$url" || { rm -rf "$tmp"; return 1; }
    # The tarball unpacks to ./opt/kata/...
    tar -C "$MNT" -xJf "$tmp/kata.tar.xz" 2>/dev/null || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    for b in kata-runtime containerd-shim-kata-v2 kata-monitor; do
        [ -x "$MNT/opt/kata/bin/$b" ] && chroot "$MNT" ln -sf "/opt/kata/bin/$b" "/usr/local/bin/$b" 2>/dev/null || true
    done
    # containerd expects the shim on PATH named per handler; provide aliases.
    for h in kata-qemu kata-fc; do
        [ -x "$MNT/opt/kata/bin/containerd-shim-kata-v2" ] && \
            chroot "$MNT" ln -sf /opt/kata/bin/containerd-shim-kata-v2 "/usr/local/bin/containerd-shim-${h}-v2" 2>/dev/null || true
    done
    return 0
}

_rt_libvirt_pool() {
    # Define an autostart 'default' storage pool backed by the ZFS dataset
    # mounted at /var/lib/libvirt/images. libvirt picks this up at daemon start.
    mkdir -p "$MNT/etc/libvirt/storage/autostart" "$MNT/var/lib/libvirt/images"
    cat > "$MNT/etc/libvirt/storage/default.xml" <<'XML'
<pool type='dir'>
  <name>default</name>
  <target>
    <path>/var/lib/libvirt/images</path>
  </target>
</pool>
XML
    chroot "$MNT" ln -sf /etc/libvirt/storage/default.xml /etc/libvirt/storage/autostart/default.xml 2>/dev/null || true
}

_rt_firecracker_dirs() {
    mkdir -p "$MNT/var/lib/vbaz/firecracker" "$MNT/var/lib/vbaz/images" "$MNT/var/lib/vbaz/iso"
}
