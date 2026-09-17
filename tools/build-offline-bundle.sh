#!/bin/sh
# v-BAZ :: offline bundle builder
#
# Produces everything the first boot needs so it can run with NO network at
# all: the Alpine netboot kernel/initramfs/modloop plus a LOCAL, SIGNED apk
# repository containing the full package closure v-BAZ installs (base + virt +
# zfs + docker/containerd + Wi-Fi + firmware + ...). The Windows installer then
# stages this bundle onto the ESP with  Install-VBaz.ps1 -Offline <dir>  and the
# provisioner installs from it locally, bringing up Wi-Fi from the offline
# packages - no Ethernet, no tether.
#
# MUST run where `apk` exists (Alpine). Easiest from any OS via a container:
#
#   docker run --rm -v "$PWD/offline:/out" -v "$PWD:/repo" alpine:3.21 \
#       sh /repo/tools/build-offline-bundle.sh /out
#
# On an Alpine box:  doas sh tools/build-offline-bundle.sh ./offline
#
# Output layout (point Install-VBaz.ps1 -Offline at this dir):
#   <out>/boot/{vmlinuz-lts,initramfs-lts,modloop-lts}
#   <out>/apks/<arch>/{*.apk,APKINDEX.tar.gz}     (signed)
#   <out>/keys/<name>.rsa.pub                      (repo public key)
#   <out>/bundle.env                               (branch/arch/flavor manifest)
set -eu

OUT=${1:?usage: build-offline-bundle.sh <output-dir>}
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd 2>/dev/null || echo /repo)
BRANCH=${VBAZ_BRANCH:-v3.21}
VER=${VBAZ_VERSION:-3.21.0}
ARCH=${VBAZ_ARCH:-x86_64}
FLAVOR=${VBAZ_FLAVOR:-lts}
MIRROR=${VBAZ_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
# Firmware package - narrow to your chip to shrink the bundle a lot,
# e.g. VBAZ_WIFI_FIRMWARE=linux-firmware-iwlwifi
FIRMWARE=${VBAZ_WIFI_FIRMWARE:-linux-firmware}

command -v apk >/dev/null 2>&1 || { echo "this builder needs apk (run it on Alpine or via the docker one-liner in the header)" >&2; exit 1; }

echo "== v-BAZ offline bundle: $BRANCH/$ARCH ($FLAVOR) -> $OUT =="
apk add --no-cache --quiet apk-tools abuild wget tar 2>/dev/null || true

mkdir -p "$OUT/boot" "$OUT/apks/$ARCH" "$OUT/keys"

# --- 1. netboot kernel/initramfs/modloop ----------------------------------
nb="$MIRROR/$BRANCH/releases/$ARCH/netboot-$VER"
for f in vmlinuz-$FLAVOR initramfs-$FLAVOR modloop-$FLAVOR; do
    echo "  fetch $f"
    wget -qO "$OUT/boot/${f%-$FLAVOR}-lts" "$nb/$f" 2>/dev/null \
        || wget -qO "$OUT/boot/${f%-$FLAVOR}-lts" "$MIRROR/$BRANCH/releases/$ARCH/netboot/$f"
done

# --- 2. package closure ----------------------------------------------------
# Pull the set names from packages.list so this stays in sync, plus the extras
# installed by the feature modules.
pkgs_from_set() {
    awk -v w="set:$1" '/^set:/{c=($0==w);next} c && $0!~/^#/ && NF{print}' "$REPO/alpine/provision/packages.list" 2>/dev/null
}
BASE=$(pkgs_from_set base)
VIRT=$(pkgs_from_set virt)
FC=$(pkgs_from_set firecracker)
EXTRAS="linux-$FLAVOR mkinitfs zfs zfs-$FLAVOR docker docker-cli-compose containerd cni-plugins nerdctl \
        wpa_supplicant wireless-regdb iw $FIRMWARE device-mapper thin-provisioning-tools \
        sbsigntool openssl zram-init shadow"
PKGS=$(printf '%s\n' $BASE $VIRT $FC $EXTRAS | sort -u)
echo "  packages: $(printf '%s ' $PKGS)"

reposf=$(mktemp)
printf '%s\n%s\n' "$MIRROR/$BRANCH/main" "$MIRROR/$BRANCH/community" > "$reposf"

echo "  fetching package closure (apk fetch --recursive)..."
# shellcheck disable=SC2086
apk fetch --recursive --repositories-file "$reposf" --output "$OUT/apks/$ARCH" $PKGS \
    || { echo "apk fetch failed (some package may not exist in $BRANCH; check the list)" >&2; exit 1; }

# --- 3. index + sign -------------------------------------------------------
echo "  indexing + signing"
( cd "$OUT/apks/$ARCH" && apk index --rewrite-arch "$ARCH" -o APKINDEX.tar.gz ./*.apk )
key="$OUT/keys/vbaz-offline"
if [ ! -f "$key.rsa" ]; then abuild-keygen -a -n -q 2>/dev/null || openssl genrsa -out "$key.rsa" 2048 2>/dev/null; fi
# abuild-keygen puts keys under ~/.abuild; find the private key it made.
priv=$(ls -1 "$HOME"/.abuild/*.rsa 2>/dev/null | head -n1)
[ -n "$priv" ] || priv="$key.rsa"
pub="$priv.pub"; [ -f "$pub" ] || openssl rsa -in "$priv" -pubout -out "$pub" 2>/dev/null
abuild-sign -k "$priv" "$OUT/apks/$ARCH/APKINDEX.tar.gz" 2>/dev/null \
    || echo "  WARN: could not sign index; the provisioner will need --allow-untrusted"
cp "$pub" "$OUT/keys/$(basename "$pub")" 2>/dev/null || true

# --- 4. manifest -----------------------------------------------------------
cat > "$OUT/bundle.env" <<EOF
VBAZ_BRANCH='$BRANCH'
VBAZ_VERSION='$VER'
VBAZ_ARCH='$ARCH'
VBAZ_FLAVOR='$FLAVOR'
VBAZ_OFFLINE_FIRMWARE='$FIRMWARE'
EOF
rm -f "$reposf"

echo "== done. Bundle at $OUT =="
du -sh "$OUT" 2>/dev/null || true
echo "Next (on Windows): .\\Install-VBaz.ps1 -Offline <path-to-this-dir> -WifiSSID ... -SetWifiPassword ..."
