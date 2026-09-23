#!/bin/sh
# Create the Kali Live persistence filesystem inside an already-mounted data tree.
set -eu
target=${1:?usage: prepare-kali-persistence.sh DATA_DIR SIZE_MIB}
size_mib=${2:?usage: prepare-kali-persistence.sh DATA_DIR SIZE_MIB}
case "$size_mib" in ''|*[!0-9]*) echo "size must be an integer MiB value" >&2; exit 2;; esac
[ "$size_mib" -ge 64 ] || { echo "persistence image must be at least 64 MiB" >&2; exit 2; }
[ -d "$target" ] || { echo "data directory not found: $target" >&2; exit 2; }
command -v mkfs.ext4 >/dev/null 2>&1 || { echo "mkfs.ext4 is required" >&2; exit 2; }
guest_dir="$target/guests/kali"
image="$guest_dir/persistence.raw"
metadata="$guest_dir/persistence.json"
[ ! -e "$image" ] && [ ! -e "$metadata" ] || { echo "refusing to overwrite existing Kali persistence state" >&2; exit 2; }
stage=$(mktemp -d)
cleanup(){ rm -rf "$stage"; }
trap cleanup EXIT HUP INT TERM
printf '/ union\n' > "$stage/persistence.conf"
mkdir -p "$guest_dir"
truncate -s "${size_mib}M" "$image"
mkfs.ext4 -q -F -L persistence -d "$stage" "$image"
cat > "$metadata" <<EOF
{
  "schema": "vbaz.kali-persistence.v1",
  "image": "persistence.raw",
  "filesystem": "ext4",
  "label": "persistence",
  "size_mib": $size_mib,
  "mount_rules": ["/ union"]
}
EOF
cleanup
trap - EXIT HUP INT TERM
echo "Kali persistence prepared: $image"
