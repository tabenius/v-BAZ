#!/bin/sh
# =====================================================================
# v-BAZ first-boot provisioner (runs on the diskless/in-RAM Alpine)
# ---------------------------------------------------------------------
# 1. Find the VBAZ_ROOT partition (by GPT type GUID - never guesses).
# 2. Format it ext4 and mount it.
# 3. Install a minimal Alpine "sys" system into it (manual, controlled).
# 4. Install the KVM / libvirt / QEMU (+ optional Firecracker) stack.
# 5. Create the operator account, enable services, write fstab.
# 6. Copy the installed kernel/initramfs to the ESP and flip the rEFInd
#    default to boot the installed system directly next time.
#
# Designed to be idempotent and to touch ONLY the v-BAZ partition + our
# own ESP subdirectory. It never repartitions and never edits the Windows
# bootloader files.
# =====================================================================
set -eu

log()  { echo "[vbaz] $*"; }
die()  { echo "[vbaz][FATAL] $*" >&2; exit 1; }

ENVF=/etc/vbaz/vbaz.env
[ -f "$ENVF" ] || die "missing $ENVF"
# shellcheck disable=SC1090
. "$ENVF"

# Optional feature modules (ZFS pool, guest runtimes, Secure Boot signing).
for _m in /etc/vbaz/vbaz-storage.sh /etc/vbaz/vbaz-runtimes.sh /etc/vbaz/vbaz-thinpool.sh /etc/vbaz/vbaz-secureboot.sh; do
    # shellcheck disable=SC1090
    [ -f "$_m" ] && . "$_m"
done

: "${VBAZ_ROOTTYPE:?}" "${VBAZ_ROOTLABEL:?}" "${VBAZ_MIRROR:?}" "${VBAZ_BRANCH:?}"
: "${VBAZ_ARCH:?}" "${VBAZ_FLAVOR:?}" "${VBAZ_HOSTNAME:?}" "${VBAZ_USERNAME:?}"
: "${VBAZ_TIMEZONE:?}" "${VBAZ_ESPSUBDIR:?}" "${VBAZ_PACKAGE_SETS:?}"

MNT=/mnt/vbaz-root
ESPMNT=/mnt/vbaz-esp
MAIN="$VBAZ_MIRROR/$VBAZ_BRANCH/main"
COMMUNITY="$VBAZ_MIRROR/$VBAZ_BRANCH/community"

# Verbose mode: VBAZ_VERBOSE=1 turns on shell tracing (captured by the
# local.d hook into /var/log/vbaz-provision.log) and debug() output.
: "${VBAZ_VERBOSE:=0}"
debug() { [ "$VBAZ_VERBOSE" = "1" ] && echo "[vbaz][dbg] $*" || true; }
if [ "$VBAZ_VERBOSE" = "1" ]; then
    log "verbose mode on (shell tracing enabled)"
    set -x
fi

# ---------------------------------------------------------------------
# 0. Networking + apk
# ---------------------------------------------------------------------
ensure_network() {
    if ip route | grep -q default; then return 0; fi
    log "bringing up networking (dhcp)"
    for i in $(ls /sys/class/net | grep -v lo); do
        ip link set "$i" up 2>/dev/null || true
        udhcpc -i "$i" -n -q 2>/dev/null && return 0 || true
    done
    ip route | grep -q default || die "no network - the installer needs to reach $VBAZ_MIRROR"
}

setup_apk() {
    mkdir -p /etc/apk
    printf '%s\n%s\n' "$MAIN" "$COMMUNITY" > /etc/apk/repositories
    apk update
    apk add --no-cache e2fsprogs util-linux blkid lsblk sfdisk dosfstools >/dev/null
}

# ---------------------------------------------------------------------
# 1. Locate the target partition by GPT type GUID
# ---------------------------------------------------------------------
find_root_part() {
    # lsblk PARTTYPE is the GPT type GUID; match ours exactly.
    dev=$(lsblk -rno NAME,PARTTYPE -p 2>/dev/null \
          | awk -v t="$VBAZ_ROOTTYPE" 'tolower($2)==tolower(t){print $1; exit}')
    [ -n "${dev:-}" ] || die "could not find a partition of type $VBAZ_ROOTTYPE (VBAZ_ROOT)"
    echo "$dev"
}

find_esp() {
    dev=$(lsblk -rno NAME,PARTTYPE -p 2>/dev/null \
          | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print $1; exit}')
    [ -n "${dev:-}" ] || die "could not find the EFI System Partition"
    echo "$dev"
}

# ---------------------------------------------------------------------
# 2. Format + mount root (idempotent: skip mkfs if already our ext4)
# ---------------------------------------------------------------------
prepare_root() {
    ROOTDEV=$(find_root_part)
    log "VBAZ_ROOT device: $ROOTDEV"

    # --- defensive guards before anything destructive --------------------
    # 1) The device MUST carry our GPT type GUID (belt-and-suspenders even
    #    though find_root_part matched on it).
    ptype=$(blkid -s PARTTYPE -o value "$ROOTDEV" 2>/dev/null | tr 'A-Z' 'a-z')
    want=$(printf '%s' "$VBAZ_ROOTTYPE" | tr 'A-Z' 'a-z')
    [ "$ptype" = "$want" ] || die "refusing to format $ROOTDEV: PARTTYPE '$ptype' != VBAZ_ROOT '$want'"
    # 2) Never format the ESP.
    esp=$(find_esp 2>/dev/null || true)
    [ "$ROOTDEV" != "$esp" ] || die "refusing to format $ROOTDEV: it is the ESP"
    # 3) A tagged partition holding NTFS almost certainly means a mis-tag;
    #    refuse rather than risk Windows data.
    curfs=$(blkid -s TYPE -o value "$ROOTDEV" 2>/dev/null || true)
    [ "$curfs" != "ntfs" ] || die "refusing to format $ROOTDEV: it contains NTFS (mis-tag?)"
    # 4) Not currently mounted.
    if awk -v d="$ROOTDEV" '$1==d{found=1} END{exit !found}' /proc/mounts 2>/dev/null; then
        die "refusing to format $ROOTDEV: it is currently mounted"
    fi

    curlabel=$(blkid -s LABEL -o value "$ROOTDEV" 2>/dev/null || true)
    if [ "$curfs" = "ext4" ] && [ "$curlabel" = "$VBAZ_ROOTLABEL" ] && [ -f "$MNT/.vbaz-installed" ]; then
        log "existing v-BAZ ext4 root found; reusing"
    else
        log "formatting $ROOTDEV as ext4 (label $VBAZ_ROOTLABEL)"
        mkfs.ext4 -F -L "$VBAZ_ROOTLABEL" "$ROOTDEV" >/dev/null || die "mkfs.ext4 failed on $ROOTDEV"
    fi
    mkdir -p "$MNT"
    mountpoint -q "$MNT" || mount "$ROOTDEV" "$MNT"

    # optional swap partition
    SWAPDEV=$(lsblk -rno NAME,PARTTYPE -p 2>/dev/null \
              | awk 'tolower($2)=="0657fd6d-a4ab-43c4-84e5-0933c84b4f4f"{print $1; exit}' || true)
    if [ -n "${SWAPDEV:-}" ]; then
        log "initialising swap on $SWAPDEV"
        mkswap -L "${VBAZ_SWAPLABEL:-VBAZ_SWAP}" "$SWAPDEV" >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------
# 3. Base system install into $MNT
# ---------------------------------------------------------------------
install_base() {
    log "installing Alpine base into $MNT"
    mkdir -p "$MNT/etc/apk"
    printf '%s\n%s\n' "$MAIN" "$COMMUNITY" > "$MNT/etc/apk/repositories"

    apk add --root "$MNT" --initdb --arch "$VBAZ_ARCH" -U --allow-untrusted \
        -X "$MAIN" -X "$COMMUNITY" \
        $(read_set base) >/dev/null

    # Pseudo-filesystems for chroot work.
    for d in proc sys dev; do mkdir -p "$MNT/$d"; done
    mount -t proc none "$MNT/proc"
    mount --rbind /sys "$MNT/sys"
    mount --rbind /dev "$MNT/dev"

    # fstab (root by label; swap if present; ESP not auto-mounted).
    cat > "$MNT/etc/fstab" <<EOF
LABEL=$VBAZ_ROOTLABEL   /       ext4    rw,relatime     0 1
EOF
    if [ -n "${SWAPDEV:-}" ]; then
        echo "LABEL=${VBAZ_SWAPLABEL:-VBAZ_SWAP}   none   swap   sw   0 0" >> "$MNT/etc/fstab"
    fi

    echo "$VBAZ_HOSTNAME" > "$MNT/etc/hostname"
    cp /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null || true
}

# read package names for a given set from packages.list
read_set() {
    want="$1"
    awk -v w="set:$1" '
        /^set:/ { cur=($0==w); next }
        cur && $0 !~ /^#/ && NF { print }
    ' /etc/vbaz/packages.list
}

# ---------------------------------------------------------------------
# 4. Virtualization stack + kernel, inside the chroot
# ---------------------------------------------------------------------
install_stack() {
    log "installing kernel + selected package sets: $VBAZ_PACKAGE_SETS"

    # Always need a kernel + initramfs tooling for the installed system.
    chroot "$MNT" /sbin/apk add --no-cache linux-$VBAZ_FLAVOR mkinitfs >/dev/null

    for s in $VBAZ_PACKAGE_SETS; do
        [ "$s" = "base" ] && continue
        pkgs=$(read_set "$s")
        [ -n "$pkgs" ] || continue
        if [ "$s" = "firecracker" ]; then
            install_firecracker || log "firecracker: continued despite install issue"
            continue
        fi
        log "  set '$s': $(echo $pkgs | tr '\n' ' ')"
        # shellcheck disable=SC2086
        chroot "$MNT" /sbin/apk add --no-cache $pkgs >/dev/null || \
            log "  WARN: some packages in set '$s' failed (check repo/branch)"
    done

    # Timezone.
    if [ -f "$MNT/usr/share/zoneinfo/$VBAZ_TIMEZONE" ]; then
        chroot "$MNT" ln -sf "/usr/share/zoneinfo/$VBAZ_TIMEZONE" /etc/localtime
        echo "$VBAZ_TIMEZONE" > "$MNT/etc/timezone"
    fi
}

install_firecracker() {
    log "installing Firecracker"
    if chroot "$MNT" /sbin/apk add --no-cache firecracker >/dev/null 2>&1; then
        log "  firecracker from apk"
        return 0
    fi
    # Fallback: fetch the static release binary matching the arch.
    log "  firecracker apk unavailable; fetching upstream static binary"
    fcarch="$VBAZ_ARCH"; [ "$fcarch" = "amd64" ] && fcarch="x86_64"
    ver=$(wget -qO- https://api.github.com/repos/firecracker-microvm/firecracker/releases/latest \
          | awk -F'"' '/"tag_name"/{print $4; exit}')
    [ -n "$ver" ] || return 1
    url="https://github.com/firecracker-microvm/firecracker/releases/download/${ver}/firecracker-${ver}-${fcarch}.tgz"
    tmp=$(mktemp -d)
    wget -qO "$tmp/fc.tgz" "$url" || return 1
    tar -xzf "$tmp/fc.tgz" -C "$tmp"
    install -m0755 "$tmp"/release-*/firecracker-* "$MNT/usr/local/bin/firecracker" 2>/dev/null || return 1
    install -m0755 "$tmp"/release-*/jailer-*     "$MNT/usr/local/bin/jailer"      2>/dev/null || true
    rm -rf "$tmp"
    log "  firecracker $ver installed to /usr/local/bin"
}

# ---------------------------------------------------------------------
# 5. Accounts, services, KVM group
# ---------------------------------------------------------------------
configure_system() {
    log "configuring services and the operator account"

    # Enable core + virtualization services in the installed system.
    for svc in devfs dmesg mdev hwdrivers modloop; do
        chroot "$MNT" rc-update add "$svc" sysinit 2>/dev/null || true
    done
    for svc in hwclock modules sysctl hostname bootmisc syslog; do
        chroot "$MNT" rc-update add "$svc" boot 2>/dev/null || true
    done
    for svc in dbus sshd chronyd networking local; do
        chroot "$MNT" rc-update add "$svc" default 2>/dev/null || true
    done
    # libvirt + its network only if the virt set was installed.
    if echo "$VBAZ_PACKAGE_SETS" | grep -qw virt; then
        chroot "$MNT" rc-update add libvirtd default 2>/dev/null || true
        chroot "$MNT" rc-update add virtlogd default 2>/dev/null || true
        # kvm modules load at boot
        printf 'kvm\nkvm_intel\nkvm_amd\n' > "$MNT/etc/modules-load.d/kvm.conf" 2>/dev/null || \
            printf 'kvm\nkvm_intel\nkvm_amd\n' >> "$MNT/etc/modules"
    fi

    # networking config (dhcp on first ethernet).
    cat > "$MNT/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

    # Operator account, added to kvm/libvirt/wheel groups; wheel gets doas.
    chroot "$MNT" adduser -D -g "v-BAZ operator" "$VBAZ_USERNAME" 2>/dev/null || true
    for g in wheel kvm libvirt; do
        chroot "$MNT" addgroup "$VBAZ_USERNAME" "$g" 2>/dev/null || true
    done
    echo 'permit persist :wheel' > "$MNT/etc/doas.d/wheel.conf" 2>/dev/null || \
        { mkdir -p "$MNT/etc/doas.d"; echo 'permit persist :wheel' > "$MNT/etc/doas.d/wheel.conf"; }

    # Password: transient secret if provided, else force change at first login.
    if [ -f /etc/vbaz/secret.pw ]; then
        pw=$(cat /etc/vbaz/secret.pw)
        echo "$VBAZ_USERNAME:$pw" | chroot "$MNT" chpasswd 2>/dev/null || true
        # shred the transient secret from RAM overlay and (later) the ESP.
        shred -u /etc/vbaz/secret.pw 2>/dev/null || rm -f /etc/vbaz/secret.pw
        log "operator password set from transient secret (now shredded)"
    else
        # lock, then expire so the user must set a password on first login.
        chroot "$MNT" passwd -u "$VBAZ_USERNAME" 2>/dev/null || true
        chroot "$MNT" chage -d 0 "$VBAZ_USERNAME" 2>/dev/null || \
            chroot "$MNT" passwd -e "$VBAZ_USERNAME" 2>/dev/null || true
        log "operator account will require setting a password at first login"
    fi

    # Swap: with no dedicated swap partition, use compressed RAM swap (zram).
    swapdev=$(lsblk -rno NAME,PARTTYPE -p 2>/dev/null \
              | awk 'tolower($2)=="0657fd6d-a4ab-43c4-84e5-0933c84b4f4f"{print $1;exit}' || true)
    if [ -z "${swapdev:-}" ]; then
        log "configuring zram swap (no swap partition)"
        if chroot "$MNT" /sbin/apk add --no-cache zram-init >/dev/null 2>&1; then
            cat > "$MNT/etc/conf.d/zram-init" <<'EOF'
load_on_start=yes
unload_on_stop=yes
num_devices=1
type0=swap
flag0=8000
size0=2048
maxs0=4
algo0=zstd
labl0=zram-swap
EOF
            echo zram >> "$MNT/etc/modules-load.d/zram.conf" 2>/dev/null || echo zram >> "$MNT/etc/modules"
            chroot "$MNT" rc-update add zram-init boot 2>/dev/null || true
        else
            log "  zram-init unavailable; leaving without swap (add a swapfile later if needed)"
        fi
    fi

    # Build the initramfs for the installed system.
    kver=$(chroot "$MNT" sh -c "ls /lib/modules | head -n1")
    chroot "$MNT" mkinitfs "$kver" 2>/dev/null || chroot "$MNT" mkinitfs || true

    touch "$MNT/.vbaz-installed"
}

# ---------------------------------------------------------------------
# 6. Flip the boot entry: installed kernel/initramfs -> ESP, enable stanza
# ---------------------------------------------------------------------
finalize_boot() {
    log "publishing installed kernel to the ESP and switching default boot"
    ESPDEV=$(find_esp)
    mkdir -p "$ESPMNT"
    mountpoint -q "$ESPMNT" || mount "$ESPDEV" "$ESPMNT"
    dir="$ESPMNT/EFI/$VBAZ_ESPSUBDIR"
    mkdir -p "$dir"

    kimg=$(ls "$MNT"/boot/vmlinuz-* 2>/dev/null | head -n1)
    iimg=$(ls "$MNT"/boot/initramfs-* 2>/dev/null | head -n1)
    [ -n "$kimg" ] && [ -n "$iimg" ] || die "installed kernel/initramfs not found under $MNT/boot"
    cp "$kimg" "$dir/vmlinuz-lts-installed"
    cp "$iimg" "$dir/initramfs-lts-installed"

    # Enable the "(installed)" stanza and make it the default, disable the
    # provisioner stanza. Simplest robust edit: regenerate the two stanzas.
    conf="$dir/refind.conf"
    if [ -f "$conf" ]; then
        # Enable the "(installed)" stanza and make it the default; neutralise
        # the provisioner stanza. NOTE: this runs under BUSYBOX sed, so only
        # POSIX regex (e.g. [[:space:]]) is used - no \s, and no `1i` insert.
        sed -i '/(installed)/,/^}/ s/^\([[:space:]]*\)disabled/\1# vbaz-enabled/' "$conf" 2>/dev/null || true
        # default_selection matches by substring of the entry title; the
        # "(installed)" suffix is unique to the installed stanza.
        grep -q '^default_selection' "$conf" 2>/dev/null || \
            printf 'default_selection "(installed)"\n' >> "$conf"
        sed -i 's/vbaz_provision=1/vbaz_provisioned=1/' "$conf" 2>/dev/null || true
        # Verify the flip actually took; if not, say so loudly (non-fatal).
        if grep -q '^[[:space:]]*disabled' "$conf" 2>/dev/null; then
            log "WARN: could not enable the installed rEFInd stanza - check $conf by hand"
        fi
    else
        log "WARN: $conf missing - the installed system may not become the default boot entry"
    fi

    # Remove the apkovl from the ESP root so the diskless overlay stops
    # loading; the installed system now boots directly.
    rm -f "$ESPMNT/vbaz.apkovl.tar.gz" 2>/dev/null || true
    sync
    umount "$ESPMNT" 2>/dev/null || true
}

cleanup() {
    rc=$?
    for m in "$MNT/proc" "$MNT/sys" "$MNT/dev"; do
        mountpoint -q "$m" && umount -R "$m" 2>/dev/null || true
    done
    sync
    [ "$rc" -ne 0 ] && log "provisioner ABORTED (exit $rc) - see /var/log/vbaz-provision.log"
    return 0
}

# ---------------------------------------------------------------------
main() {
    trap cleanup EXIT
    ensure_network
    setup_apk
    prepare_root
    install_base
    install_stack
    configure_system
    command -v setup_storage  >/dev/null 2>&1 && setup_storage
    command -v setup_runtimes >/dev/null 2>&1 && setup_runtimes
    command -v setup_thinpool >/dev/null 2>&1 && setup_thinpool
    command -v sign_kernel    >/dev/null 2>&1 && sign_kernel
    finalize_boot
    mkdir -p /var/lib/vbaz
    touch /var/lib/vbaz/provisioned
    log "DONE. Rebooting into the installed v-BAZ system in 10s (Ctrl-C to stay)."
    sleep 10
    reboot
}
main "$@"
