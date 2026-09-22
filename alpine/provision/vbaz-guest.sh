#!/bin/sh
# v-BAZ :: Ubuntu guest VM (sourced by vbaz-provision.sh)
#
# Provisions a cloud-init Ubuntu guest under libvirt/KVM with a default login.
# Enabled by the 'guest' package set. All the runtime work (image fetch, seed
# build, domain define/start) happens at boot via an OpenRC service, when
# libvirtd and the ZFS pool are live -- never in the RAM installer.
#
# The Ubuntu cloud image is large (~600 MB), too big for a Windows ESP, so it is
# NOT staged there: at first boot the service downloads it (online), or uses a
# qcow2 the operator pre-placed at /var/lib/vbaz/guest/base.qcow2 (off-grid).
#
# Runs against $MNT in the installer. Best-effort: a hiccup must not abort the
# base install of a working virtualization host.

setup_guest() {
    echo "$VBAZ_PACKAGE_SETS" | grep -qw guest || return 0
    set +e
    log "guest: installing Ubuntu guest VM provisioner"

    _g_name="${VBAZ_GUEST_NAME:-ubuntu}"
    _g_user="${VBAZ_GUEST_USER:-ragbaz}"
    _g_pass="${VBAZ_GUEST_PASSWORD:-ragbaz}"
    _g_url="${VBAZ_GUEST_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
    _g_vcpus="${VBAZ_GUEST_VCPUS:-2}"
    _g_mem="${VBAZ_GUEST_MEM_MB:-2048}"
    _g_disk="${VBAZ_GUEST_DISK_GB:-20}"
    _g_state="/var/lib/vbaz/guest"

    # Host tooling the service needs at boot: xorriso builds the cloud-init seed
    # ISO, curl fetches the cloud image. qemu-img/virt-install/libvirt come from
    # the 'virt' set. Best-effort; unavailability must not abort the install.
    chroot "$MNT" /sbin/apk add --no-cache xorriso curl >/dev/null 2>&1 \
        || log "  (xorriso/curl apk unavailable; the guest service needs them at boot)"

    mkdir -p "$MNT/etc/vbaz"
    cat > "$MNT/etc/vbaz/guest.env" <<ENV
GUEST_NAME='$_g_name'
GUEST_USER='$_g_user'
GUEST_PASSWORD='$_g_pass'
GUEST_IMAGE_URL='$_g_url'
GUEST_VCPUS='$_g_vcpus'
GUEST_MEM_MB='$_g_mem'
GUEST_DISK_GB='$_g_disk'
GUEST_STATE='$_g_state'
ENV
    # guest.env carries the default guest password; keep it root-only.
    chmod 0600 "$MNT/etc/vbaz/guest.env" 2>/dev/null || true

    mkdir -p "$MNT$_g_state"

    _guest_install_service
    log "guest: service installed (starts after libvirtd at boot; user '$_g_user')"
}

# The OpenRC service. Image acquisition + domain launch happen at boot, when
# libvirtd and the ZFS pool are live -- none of which exist in the RAM installer.
_guest_install_service() {
    cat > "$MNT/etc/init.d/vbaz-guest" <<'INITD'
#!/sbin/openrc-run
description="v-BAZ Ubuntu guest VM (cloud-init)"

depend() {
    need libvirtd
    after vbaz-storage net
}

: "${GUEST_ENV:=/etc/vbaz/guest.env}"
[ -f "$GUEST_ENV" ] && . "$GUEST_ENV"
: "${GUEST_NAME:=ubuntu}"
: "${GUEST_USER:=ragbaz}"
: "${GUEST_PASSWORD:=ragbaz}"
: "${GUEST_VCPUS:=2}"
: "${GUEST_MEM_MB:=2048}"
: "${GUEST_DISK_GB:=20}"
: "${GUEST_STATE:=/var/lib/vbaz/guest}"

# Ensure the libvirt default NAT network is defined + running (guests attach to
# it). Missing 'default' net is not fatal here; the domain start would report it.
_guest_net() {
    virsh net-info default >/dev/null 2>&1 || return 0
    virsh net-start default >/dev/null 2>&1 || true
    virsh net-autostart default >/dev/null 2>&1 || true
}

# Resolve the base cloud image into BASE_IMG: a pre-placed qcow2 wins (off-grid);
# otherwise download it (online). Sets BASE_IMG, returns non-zero if unavailable.
_guest_base_image() {
    BASE_IMG="$GUEST_STATE/base.qcow2"
    [ -f "$BASE_IMG" ] && return 0
    [ -n "${GUEST_IMAGE_URL:-}" ] || return 1
    einfo "guest: downloading Ubuntu cloud image (large; one-time)"
    if curl -fL --retry 3 -o "$BASE_IMG.part" "$GUEST_IMAGE_URL" && mv "$BASE_IMG.part" "$BASE_IMG"; then
        return 0
    fi
    rm -f "$BASE_IMG.part"
    return 1
}

# Build the cloud-init NoCloud seed ISO into SEED_ISO. user-data creates the
# default login (password auth, passwordless sudo). Idempotent.
_guest_seed() {
    SEED_ISO="$GUEST_STATE/seed.iso"
    [ -f "$SEED_ISO" ] && return 0
    _d=$(mktemp -d) || return 1
    cat > "$_d/meta-data" <<META
instance-id: $GUEST_NAME
local-hostname: $GUEST_NAME
META
    cat > "$_d/user-data" <<USER
#cloud-config
hostname: $GUEST_NAME
ssh_pwauth: true
users:
  - name: $GUEST_USER
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: false
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
chpasswd:
  expire: false
  users:
    - name: $GUEST_USER
      password: $GUEST_PASSWORD
      type: text
USER
    if xorriso -as mkisofs -output "$SEED_ISO" -volid CIDATA -joliet -rock \
        "$_d/user-data" "$_d/meta-data" >/dev/null 2>&1; then
        rm -rf "$_d"
        return 0
    fi
    rm -rf "$_d"
    return 1
}

start_pre() {
    mkdir -p "$GUEST_STATE"
    _guest_net
}

start() {
    ebegin "Starting Ubuntu guest ($GUEST_NAME)"
    # Already defined? Just make sure it is running.
    if virsh dominfo "$GUEST_NAME" >/dev/null 2>&1; then
        virsh start "$GUEST_NAME" >/dev/null 2>&1 || true
        eend 0
        return 0
    fi
    if ! _guest_base_image; then
        eerror "guest: no base image (place $GUEST_STATE/base.qcow2, or set GUEST_IMAGE_URL for an online fetch)"
        eend 1
        return 1
    fi
    if ! _guest_seed; then
        eerror "guest: could not build the cloud-init seed ISO (xorriso missing?)"
        eend 1
        return 1
    fi
    _overlay="$GUEST_STATE/$GUEST_NAME.qcow2"
    if [ ! -f "$_overlay" ]; then
        if ! qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$_overlay" "${GUEST_DISK_GB}G" >/dev/null 2>&1; then
            eerror "guest: could not create the overlay disk"
            eend 1
            return 1
        fi
    fi
    # Import the disk (no OS install; the cloud image is ready), attach the seed
    # ISO as a cdrom, join the default NAT network, headless, autostart.
    virt-install --name "$GUEST_NAME" \
        --memory "$GUEST_MEM_MB" --vcpus "$GUEST_VCPUS" \
        --os-variant detect=on,require=off \
        --import \
        --disk "path=$_overlay,format=qcow2,bus=virtio" \
        --disk "path=$SEED_ISO,device=cdrom" \
        --network network=default,model=virtio \
        --graphics none --noautoconsole --autostart >/dev/null 2>&1
    eend $?
}

stop() {
    ebegin "Stopping Ubuntu guest ($GUEST_NAME)"
    virsh shutdown "$GUEST_NAME" >/dev/null 2>&1 || true
    eend 0
}

status() {
    if virsh domstate "$GUEST_NAME" 2>/dev/null | grep -qi running; then
        einfo "guest $GUEST_NAME is running"
        return 0
    fi
    einfo "guest $GUEST_NAME is not running"
    return 3
}
INITD
    chmod +x "$MNT/etc/init.d/vbaz-guest"
    chroot "$MNT" rc-update add vbaz-guest default 2>/dev/null || true
}
