#!/bin/sh
# Copy a caller-supplied, checksum-pinned Kali ISO into portable guest storage.
set -eu
target=${1:?usage: stage-kali-iso.sh DATA_DIR ISO_FILE SHA256}
source_iso=${2:?usage: stage-kali-iso.sh DATA_DIR ISO_FILE SHA256}
expected=${3:?usage: stage-kali-iso.sh DATA_DIR ISO_FILE SHA256}
case "$expected" in
    *[!0-9a-f]*|'') echo "SHA256 must be 64 lowercase hexadecimal characters" >&2; exit 2 ;;
esac
[ "${#expected}" -eq 64 ] || { echo "SHA256 must be 64 lowercase hexadecimal characters" >&2; exit 2; }
[ -d "$target" ] || { echo "data directory not found: $target" >&2; exit 2; }
[ -f "$source_iso" ] && [ -s "$source_iso" ] || { echo "Kali ISO not found or empty: $source_iso" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 2; }
actual=$(sha256sum "$source_iso" | awk '{print $1}')
[ "$actual" = "$expected" ] || { echo "Kali ISO checksum mismatch" >&2; exit 2; }

guest_dir="$target/guests/kali"
iso="$guest_dir/kali-live.iso"
metadata="$guest_dir/media.json"
checksum_file="$guest_dir/kali-live.iso.sha256"
[ ! -e "$iso" ] && [ ! -e "$metadata" ] && [ ! -e "$checksum_file" ] || { echo "refusing to overwrite existing Kali media" >&2; exit 2; }
mkdir -p "$guest_dir"
temporary="$guest_dir/.kali-live.iso.$$"
temporary_metadata="$guest_dir/.media.json.$$"
cleanup(){ rm -f "$temporary" "$temporary_metadata"; }
trap cleanup EXIT HUP INT TERM
cp "$source_iso" "$temporary"
bytes=$(wc -c < "$temporary" | tr -d ' ')
cat > "$temporary_metadata" <<EOF
{
  "schema": "vbaz.kali-media.v1",
  "image": "kali-live.iso",
  "sha256": "$actual",
  "size_bytes": $bytes
}
EOF
mv "$temporary" "$iso"
printf '%s  %s\n' "$expected" "$(basename "$iso")" > "$checksum_file"
mv "$temporary_metadata" "$metadata"
trap - EXIT HUP INT TERM
echo "Kali ISO staged: $iso"
