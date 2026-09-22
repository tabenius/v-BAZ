# Portable USB edition (work in progress)

This is a parallel, non-destructive build path for a complete disk image. It
does **not** reuse the Windows partitioner and does not yet produce a bootable
release.

Phase 1 currently has a versioned JSON contract, pure layout calculator,
secret-reference validation, GPT/ext4 image-container builder, fixed-VHDX
conversion, and non-root dry-run tests. Installing Alpine and UEFI boot files,
then proving OVMF boot, remain required before Phase 1 is complete.

Run `tools/usb/build-image.sh --dry-run` to inspect the 64 GiB plan. The builder
creates ESP (1 GiB), Alpine root A/B (6 GiB each), configuration (512 MiB), and
an ext4 data partition using the remaining space.

The builder only creates a new regular output file, refuses overwrites and
rejects `/dev/*` output. It never writes a physical USB stick. Credentials are
file references outside version control; the example contains the requested
SSID and user name but no passwords.

Full builds need `jq`, `gdisk`, `util-linux`, `dosfstools`, and `e2fsprogs`;
VHDX conversion needs `qemu-img`. Configuration and dry-run tests need only
`jq` and do not require root.
