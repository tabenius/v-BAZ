#!/bin/sh
# v-BAZ :: portable apkovl builder (Linux equivalent of windows/lib/Apkovl.ps1)
#
# Assembles the Alpine overlay tarball the provisioner runs from, so the QEMU
# smoke test (and non-Windows users) can build the exact same overlay the
# Windows installer stages. Secure Boot MOK material is NOT included here (the
# smoke test runs with Secure Boot off).
#
# Usage: build-apkovl.sh <out.tar.gz> [vbaz.env]   (default env: test/test.env)
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:?usage: build-apkovl.sh <out.tar.gz> [vbaz.env]}
ENVF=${2:-$REPO/test/test.env}
[ -f "$ENVF" ] || { echo "env file not found: $ENVF" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1) base overlay tree (OpenRC local hook)
cp -a "$REPO/alpine/overlay/." "$work/"

# 2) provisioner + modules + support files under etc/vbaz
mkdir -p "$work/etc/vbaz"
for f in vbaz-provision.sh vbaz-storage.sh vbaz-runtimes.sh vbaz-secureboot.sh \
         vbaz-thinpool.sh packages.list; do
    cp "$REPO/alpine/provision/$f" "$work/etc/vbaz/$f"
done
cp "$REPO/alpine/answers/vbaz.answers" "$work/etc/vbaz/vbaz.answers"

# 3) environment consumed by the provisioner (verbatim)
cp "$ENVF" "$work/etc/vbaz/vbaz.env"

# 4) enable the OpenRC 'local' service so etc/local.d/*.start runs at boot
mkdir -p "$work/etc/runlevels/default"
ln -sf /etc/init.d/local "$work/etc/runlevels/default/local"

# make sure the provisioner + hook are executable inside the overlay
chmod +x "$work/etc/vbaz/"*.sh "$work/etc/local.d/vbaz-provision.start" 2>/dev/null || true

# 5) pack (gzip'd tar, paths relative to overlay root)
( cd "$work" && tar -czf "$OUT" . )
echo "apkovl built: $OUT"
