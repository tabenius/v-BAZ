# Portable USB edition (work in progress)

This is a parallel, non-destructive build path for a complete disk image. It
does **not** reuse the Windows partitioner and does not yet produce a bootable
release.

Phase 1 includes a versioned JSON contract, layout calculator, secret-reference
validation, GPT/ext4 builder, Alpine A/B root population, UEFI fallback boot,
fixed-VHDX conversion, and an OVMF boot gate in GitHub Actions.

Phase 2 is in progress. The completed storage slices create a sparse ext4 image
at `VBAZ_DATA/guests/kali/persistence.raw`, labels it `persistence`, and writes
the Kali Live `/persistence.conf` rule `/ union`. Use `--prepare-kali` to add
this storage while building an image. A pre-downloaded ISO can be staged for
offline use with `--kali-iso FILE --kali-iso-sha256 HEX`; both are required,
the checksum is verified before guest state is changed, and existing media is
never replaced. When the host is populated, it mounts `VBAZ_DATA` at
`/var/lib/vbaz` and installs an OpenRC-autostarted QEMU guest. Every guest start
rechecks the ISO checksum, attaches the separate persistence disk, uses KVM
when available (with a slower TCG fallback), and binds guest SSH only to
`127.0.0.1:2222` and VNC only to `127.0.0.1:5900`. The persistence overlay also
contains a versioned, retry-safe systemd customization unit. It creates the
configured local user without a network, installs the checksum-independent APT
package set once connectivity exists, enables SSH, and writes its completion
marker only after success. Shell installers with unresolved checksum
placeholders and plaintext passwords are not embedded. Automated ISO
acquisition and the two-host-reboot persistence proof remain open gates.

Run `tools/usb/build-image.sh --dry-run` to inspect the 64 GiB plan. The builder
creates ESP (1 GiB), Alpine root A/B (6 GiB each), configuration (512 MiB), and
an ext4 data partition using the remaining space.

The builder only creates a new regular output file, refuses overwrites and
rejects `/dev/*` output. It never writes a physical USB stick. Credentials are
file references outside version control; the example contains the requested
SSID and user name but no passwords.

Full builds need `jq`, `gdisk`, `util-linux`, `dosfstools`, `e2fsprogs`,
`systemd-boot-efi`, `curl`, and `tar`; VHDX conversion needs `qemu-img`.
Configuration and dry-run tests need only `jq` and do not require root.
