#!/bin/sh
# Fetch an image candidate and publish it only after SHA-256 verification.
set -eu
url=${1:?usage: fetch-kali-iso.sh URL SHA256 OUTPUT}
expected=${2:?usage: fetch-kali-iso.sh URL SHA256 OUTPUT}
output=${3:?usage: fetch-kali-iso.sh URL SHA256 OUTPUT}
case "$expected" in ''|*[!0-9a-f]*) echo "SHA256 must be lowercase hexadecimal" >&2; exit 2;; esac
[ "${#expected}" -eq 64 ] || { echo "SHA256 must contain 64 characters" >&2; exit 2; }
[ ! -e "$output" ] || { echo "refusing to overwrite: $output" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 2; }
mkdir -p "$(dirname "$output")"
temporary="$output.partial.$$"
cleanup(){ rm -f "$temporary"; }
trap cleanup EXIT HUP INT TERM
curl --fail --location --retry 4 --continue-at - --output "$temporary" "$url"
actual=$(sha256sum "$temporary" | awk '{print $1}')
[ "$actual" = "$expected" ] || { echo "Kali ISO checksum mismatch" >&2; exit 2; }
mv "$temporary" "$output"
trap - EXIT HUP INT TERM
echo "Kali ISO fetched and verified: $output"
