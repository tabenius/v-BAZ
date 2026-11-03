#!/bin/sh
# Rendered into the Kali persistence overlay at image-build time.
set -eu
marker=/var/lib/vbaz/first-boot-v1.done
user=@@USER@@
packages='@@PACKAGES@@'

[ ! -e "$marker" ] || exit 0
if ! id "$user" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$user"
fi

# Offline boots remain usable and retry on the next boot. The completion marker
# is written only after the requested package set is fully installed.
apt-get update
# shellcheck disable=SC2086
DEBIAN_FRONTEND=noninteractive apt-get install -y $packages
systemctl enable --now ssh
install -d -m 0755 "$(dirname "$marker")"
printf 'schema=vbaz.kali-first-boot.v1\nuser=%s\n' "$user" > "$marker"
