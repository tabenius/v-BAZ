#!/bin/sh
# v-BAZ :: Rebekah governed agentic runtime (sourced by vbaz-provision.sh)
#
# Makes Rebekah the default AI orchestration / governance platform on the
# installed host. Rebekah is a self-contained OCI image (KVM-neutral: it runs
# OpenCode, Ollama, Sylvae and WeftMark under one supervisor, with a fail-closed
# Ephor/KAGP governance connector). Here we:
#
#   1. install an OpenRC service that, at first boot, obtains the image
#      (pull from a registry, falling back to a tarball staged on the ESP) and
#      runs it inside a Kata Firecracker microVM (runtime io.containerd.kata-fc)
#      with a least-privilege capability set and a read-only root filesystem;
#   2. keep all Rebekah state on the ZFS pool (dataset vbaz/rebekah), so the
#      lean host root stays untouched.
#
# Image acquisition happens at service start (containerd + the ZFS pool + the
# devmapper thin-pool are only up at real boot), never in the RAM installer.
# Runs against $MNT in the installer. Best-effort: a hiccup must not abort the
# base install of a working virtualization host.

setup_rebekah() {
    echo "$VBAZ_PACKAGE_SETS" | grep -qw rebekah || return 0
    set +e
    log "rebekah: installing governed agentic runtime (default platform)"

    _reb_img="${VBAZ_REBEKAH_IMAGE:-ghcr.io/tabenius/rebekah:latest}"
    _reb_runtime="${VBAZ_REBEKAH_RUNTIME:-io.containerd.kata-fc.v2}"
    _reb_snap="${VBAZ_REBEKAH_SNAPSHOTTER:-devmapper}"
    _reb_model="${VBAZ_REBEKAH_OLLAMA_MODEL:-}"
    _reb_state="/var/lib/vbaz/rebekah"

    # API gateway: loopback-only by default; published on the LAN (over TLS) when
    # RebekahGatewayPublish is set. Auth is a bearer token and/or OIDC.
    _reb_gw_publish="${VBAZ_REBEKAH_GATEWAY_PUBLISH:-0}"
    _reb_gw_port="${VBAZ_REBEKAH_GATEWAY_PORT:-8443}"
    _reb_gw_expose="${VBAZ_REBEKAH_GATEWAY_EXPOSE:-weftmark}"
    _reb_gw_token="${VBAZ_REBEKAH_GATEWAY_TOKEN:-}"
    _reb_oidc_issuer="${VBAZ_REBEKAH_OIDC_ISSUER:-}"
    _reb_oidc_aud="${VBAZ_REBEKAH_OIDC_AUDIENCE:-}"

    # Host tooling the service needs at boot. containerd/kata come from the
    # runtimes module; nerdctl is the CLI the service drives, git seeds the
    # WeftMark workspace. Best-effort: unavailability must not abort the install.
    chroot "$MNT" /sbin/apk add --no-cache git >/dev/null 2>&1 || log "  (git apk unavailable)"
    chroot "$MNT" /sbin/apk add --no-cache nerdctl >/dev/null 2>&1 || log "  (nerdctl not in this branch; runtimes module or a manual install must provide it)"

    # Persisted config the runit/init script reads at boot.
    mkdir -p "$MNT/etc/vbaz"
    cat > "$MNT/etc/vbaz/rebekah.env" <<ENV
REBEKAH_IMAGE='$_reb_img'
REBEKAH_RUNTIME='$_reb_runtime'
REBEKAH_SNAPSHOTTER='$_reb_snap'
REBEKAH_OLLAMA_MODEL='$_reb_model'
REBEKAH_STATE='$_reb_state'
REBEKAH_ESP_TYPE='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
REBEKAH_ESP_SUBDIR='$VBAZ_ESPSUBDIR'
REBEKAH_GATEWAY_PUBLISH='$_reb_gw_publish'
REBEKAH_GATEWAY_PORT='$_reb_gw_port'
REBEKAH_GATEWAY_EXPOSE='$_reb_gw_expose'
REBEKAH_GATEWAY_TOKEN='$_reb_gw_token'
REBEKAH_OIDC_ISSUER='$_reb_oidc_issuer'
REBEKAH_OIDC_AUDIENCE='$_reb_oidc_aud'
ENV
    # rebekah.env may carry a gateway bearer token; keep it root-only.
    chmod 0600 "$MNT/etc/vbaz/rebekah.env" 2>/dev/null || true

    # State + workspace live on the ZFS pool (dataset mounted by vbaz-storage).
    mkdir -p "$MNT$_reb_state/state" "$MNT$_reb_state/workspace"

    _rebekah_install_service
    log "rebekah: service installed (starts after containerd + zfs at boot)"
}

# The OpenRC service. All the runtime work (image acquisition + microVM launch)
# happens at boot, when containerd, the ZFS pool and the devmapper thin-pool are
# live -- none of which exist in the RAM installer.
_rebekah_install_service() {
    cat > "$MNT/etc/init.d/rebekah" <<'INITD'
#!/sbin/openrc-run
description="Rebekah governed agentic runtime (default AI platform)"

# Ordered after everything Rebekah's microVM depends on.
depend() {
    need containerd
    after vbaz-storage vbaz-thinpool net
}

: "${REBEKAH_ENV:=/etc/vbaz/rebekah.env}"
[ -f "$REBEKAH_ENV" ] && . "$REBEKAH_ENV"

: "${REBEKAH_IMAGE:=ghcr.io/tabenius/rebekah:latest}"
: "${REBEKAH_RUNTIME:=io.containerd.kata-fc.v2}"
: "${REBEKAH_SNAPSHOTTER:=devmapper}"
: "${REBEKAH_STATE:=/var/lib/vbaz/rebekah}"
: "${REBEKAH_ESP_TYPE:=c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
: "${REBEKAH_ESP_SUBDIR:=VBAZ}"
: "${REBEKAH_GATEWAY_PUBLISH:=0}"
: "${REBEKAH_GATEWAY_PORT:=8443}"
: "${REBEKAH_GATEWAY_EXPOSE:=weftmark}"

_ctr() { nerdctl "$@"; }

# Mount the ESP read-only, run "$1 <mountpoint>", unmount; return the callback's
# status. Used by the off-grid fallbacks (image + model come from the ESP cache).
_rebekah_with_esp() {
    _cb="$1"
    espdev=$(blkid -t PARTTYPE="$REBEKAH_ESP_TYPE" -o device 2>/dev/null | head -n1)
    [ -n "$espdev" ] || return 1
    mp=$(mktemp -d) || return 1
    mount -o ro "$espdev" "$mp" 2>/dev/null || { rmdir "$mp"; return 1; }
    "$_cb" "$mp"; rc=$?
    umount "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null || true
    return "$rc"
}

# Callback: load the Rebekah image from the ESP-staged tarball.
_reb_esp_load_image() {
    d="$1/EFI/$REBEKAH_ESP_SUBDIR/rebekah"
    for c in "$d/rebekah-image.tar.gz" "$d/rebekah-image.tar"; do
        [ -f "$c" ] && { einfo "rebekah: loading image from ESP ($c)"; _ctr load < "$c" && return 0; }
    done
    return 1
}

# Callback: unpack the cached default Ollama model into Rebekah's model store.
_reb_esp_stage_model() {
    t="$1/EFI/$REBEKAH_ESP_SUBDIR/rebekah/ollama-model.tar.gz"
    [ -f "$t" ] || return 1
    dst="$REBEKAH_STATE/state/ollama/models"
    mkdir -p "$dst"
    einfo "rebekah: staging cached Ollama model from ESP (${REBEKAH_OLLAMA_MODEL:-default})"
    tar -C "$dst" -xzf "$t"
}

# Ensure the image is present in containerd: pull first (online), else fall back
# to the ESP-staged tarball (offline). No-op if the image already exists.
_rebekah_ensure_image() {
    if _ctr image inspect "$REBEKAH_IMAGE" >/dev/null 2>&1; then
        return 0
    fi
    einfo "rebekah: pulling $REBEKAH_IMAGE"
    if _ctr pull --snapshotter "$REBEKAH_SNAPSHOTTER" "$REBEKAH_IMAGE" >/dev/null 2>&1; then
        return 0
    fi
    ewarn "rebekah: registry pull failed; trying ESP-staged tarball"
    _rebekah_with_esp _reb_esp_load_image
}

# Off-grid: if the model store is empty, unpack the cached default model from the
# ESP so inference works with no network. No-op online (Ollama pulls on demand).
_rebekah_stage_model() {
    [ -d "$REBEKAH_STATE/state/ollama/models/manifests" ] && return 0
    _rebekah_with_esp _reb_esp_stage_model || true
}

# Callback: install ESP-staged gateway TLS material into the state tls dir
# (visible in the container at /var/lib/rebekah/tls via the state mount).
_reb_esp_stage_tls() {
    s="$1/EFI/$REBEKAH_ESP_SUBDIR/rebekah/tls"
    [ -f "$s/cert.pem" ] && [ -f "$s/key.pem" ] || return 1
    dst="$REBEKAH_STATE/state/tls"
    mkdir -p "$dst"
    cp "$s/cert.pem" "$dst/cert.pem" && cp "$s/key.pem" "$dst/key.pem" || return 1
    einfo "rebekah: staged gateway TLS material from ESP"
    return 0
}

# Ensure gateway TLS is present when publishing on the LAN, and readable by the
# gateway UID (10005; host UID == container UID, no userns remap). Prefer
# material already in the state dir; otherwise stage it from the ESP. Fails
# closed: a published gateway with no TLS must not come up (a bearer token would
# then cross the wire in the clear, and the container's gateway refuses to bind
# non-loopback without TLS anyway).
_rebekah_ensure_tls() {
    d="$REBEKAH_STATE/state/tls"
    if [ ! -f "$d/cert.pem" ] || [ ! -f "$d/key.pem" ]; then
        _rebekah_with_esp _reb_esp_stage_tls || return 1
    fi
    [ -f "$d/cert.pem" ] && [ -f "$d/key.pem" ] || return 1
    chown 10005:10005 "$d" "$d/cert.pem" "$d/key.pem" 2>/dev/null || true
    chmod 0750 "$d" 2>/dev/null || true
    chmod 0644 "$d/cert.pem" 2>/dev/null || true
    chmod 0640 "$d/key.pem" 2>/dev/null || true
    return 0
}

start_pre() {
    mkdir -p "$REBEKAH_STATE/state" "$REBEKAH_STATE/workspace"
    # The workspace must be a git repo with a HEAD for WeftMark; seed an empty
    # one so the runtime comes up cleanly before an operator mounts a real repo.
    if [ ! -e "$REBEKAH_STATE/workspace/.git" ]; then
        git -C "$REBEKAH_STATE/workspace" init -q 2>/dev/null || true
        git -C "$REBEKAH_STATE/workspace" config user.email rebekah@vbaz.local 2>/dev/null || true
        git -C "$REBEKAH_STATE/workspace" config user.name rebekah 2>/dev/null || true
        [ -e "$REBEKAH_STATE/workspace/.gitkeep" ] || : > "$REBEKAH_STATE/workspace/.gitkeep"
        git -C "$REBEKAH_STATE/workspace" add -A 2>/dev/null || true
        git -C "$REBEKAH_STATE/workspace" commit -qm "v-BAZ: seed Rebekah workspace" 2>/dev/null || true
    fi
    _rebekah_ensure_image || { eerror "rebekah: no image available (pull and ESP tarball both failed)"; return 1; }
    _rebekah_stage_model
    if [ "$REBEKAH_GATEWAY_PUBLISH" = 1 ]; then
        _rebekah_ensure_tls || {
            eerror "rebekah: gateway publish requested but no TLS cert/key found"
            eerror "  (looked in $REBEKAH_STATE/state/tls and the ESP rebekah/tls dir)"
            eerror "  refusing to publish the API on the LAN without TLS"
            return 1
        }
    fi
}

start() {
    ebegin "Starting Rebekah ($REBEKAH_RUNTIME)"
    _ctr rm -f rebekah >/dev/null 2>&1 || true
    # Least-privilege, read-only root -- mirrors Rebekah's own documented run
    # contract. Kata-fc puts the whole thing in a Firecracker microVM for
    # VM-grade isolation on top of Rebekah's per-service UID split. By default
    # ports stay loopback-only inside the microVM; only the authenticated gateway
    # is ever published, and only over TLS (below).
    set -- run -d --name rebekah \
        --runtime "$REBEKAH_RUNTIME" \
        --snapshotter "$REBEKAH_SNAPSHOTTER" \
        --restart unless-stopped \
        --read-only \
        --cap-drop ALL \
        --cap-add CHOWN --cap-add DAC_OVERRIDE \
        --cap-add SETUID --cap-add SETGID --cap-add KILL \
        --security-opt no-new-privileges \
        --tmpfs /run/rebekah:rw,noexec,nosuid,size=16m \
        --tmpfs /tmp:rw,noexec,nosuid,size=64m \
        -v "$REBEKAH_STATE/state:/var/lib/rebekah" \
        -v "$REBEKAH_STATE/workspace:/workspace"

    if [ "$REBEKAH_GATEWAY_PUBLISH" = 1 ]; then
        # Gateway config goes in a root-only env-file, not on argv, so the bearer
        # token never appears in the host process list. The gateway binds
        # 0.0.0.0 inside the microVM (over TLS) and we publish the port.
        _envf=/run/rebekah-gateway.env
        ( umask 077
          {
            echo "REBEKAH_GATEWAY_HOST=0.0.0.0"
            echo "REBEKAH_GATEWAY_PORT=$REBEKAH_GATEWAY_PORT"
            echo "REBEKAH_GATEWAY_EXPOSE=$REBEKAH_GATEWAY_EXPOSE"
            echo "REBEKAH_GATEWAY_TLS_CERT=/var/lib/rebekah/tls/cert.pem"
            echo "REBEKAH_GATEWAY_TLS_KEY=/var/lib/rebekah/tls/key.pem"
            [ -n "$REBEKAH_GATEWAY_TOKEN" ] && echo "REBEKAH_GATEWAY_TOKEN=$REBEKAH_GATEWAY_TOKEN"
            [ -n "$REBEKAH_OIDC_ISSUER" ] && echo "REBEKAH_OIDC_ISSUER=$REBEKAH_OIDC_ISSUER"
            [ -n "$REBEKAH_OIDC_AUDIENCE" ] && echo "REBEKAH_OIDC_AUDIENCE=$REBEKAH_OIDC_AUDIENCE"
          } > "$_envf" )
        set -- "$@" --env-file "$_envf" \
            -p "$REBEKAH_GATEWAY_PORT:$REBEKAH_GATEWAY_PORT"
    fi

    set -- "$@" "$REBEKAH_IMAGE"
    _ctr "$@" >/dev/null
    eend $?
}

stop() {
    ebegin "Stopping Rebekah"
    _ctr rm -f rebekah >/dev/null 2>&1
    eend 0
}

status() {
    if _ctr ps --format '{{.Names}}' 2>/dev/null | grep -qx rebekah; then
        einfo "Rebekah is running"; return 0
    fi
    einfo "Rebekah is not running"; return 3
}
INITD
    chmod +x "$MNT/etc/init.d/rebekah"
    chroot "$MNT" rc-update add rebekah default 2>/dev/null || true
}
