#!/bin/sh
set -eu
config=${1:-config/vbaz-usb.example.json}
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
jq -e . "$config" >/dev/null
[ "$(jq -r .schema "$config")" = vbaz.usb.v1 ]
[ "$(jq -r .image.architecture "$config")" = x86_64 ]
[ "$(jq -r .image.boot.firmware "$config")" = uefi ]
[ "$(jq -r .host.distribution "$config")" = alpine ]
[ "$(jq -r .host.storage.backend "$config")" = ext4 ]
[ "$(jq -r '.guests[]|select(.id=="kali")|.distribution' "$config")" = kali ]
[ "$(jq -r '.guests[]|select(.id=="kali")|.media.url' "$config" | grep -cE '^https://cdimage\.kali\.org/kali-[0-9]{4}\.[0-9]+/kali-linux-[0-9]{4}\.[0-9]+-live-amd64\.iso$')" -eq 1 ]
[ "$(jq -r '.guests[]|select(.id=="kali")|.media.sha256' "$config" | grep -cE '^[0-9a-f]{64}$')" -eq 1 ]
kali_version=$(jq -er '.guests[]|select(.id=="kali")|.media.version' "$config")
kali_url=$(jq -er '.guests[]|select(.id=="kali")|.media.url' "$config")
[ "$kali_url" = "https://cdimage.kali.org/kali-$kali_version/kali-linux-$kali_version-live-amd64.iso" ]
[ "$(jq -r '.guests[]|select(.id=="kali")|.persistence.mount_rules[]' "$config" | grep -cx '/ union')" -eq 1 ]
if jq -r 'paths(scalars) as $p|$p[-1]|strings' "$config" | grep -Eq '^(password|passphrase|psk)$'; then echo "inline secret field found; use *_file" >&2; exit 2; fi
sh "$(dirname "$0")/layout.sh" "$(jq -r .image.size_mib "$config")" "$(jq -r .host.root_slot_size_mib "$config")" >/dev/null
echo "configuration valid: $config"
