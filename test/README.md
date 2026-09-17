# v-BAZ smoke test

Two tiers. The first runs anywhere (and in CI) with no VM; the second boots the
real Alpine chain under QEMU + virtual UEFI.

> The Windows PowerShell side (shrink/partition/`bcdedit`) is **not** covered
> here — that needs a Windows VM. These tests cover everything from the ESP /
> rEFInd onwards: the boot chain, the apkovl overlay, and the full first-boot
> provisioner (format root, install Alpine, ZFS pool, runtimes, thin-pool,
> boot flip).

## Tier 1 — static wiring checks (no VM)

```sh
sh test/check-wiring.sh
```

Catches the bug class most likely in a two-sided installer — things that must
agree across the Windows and Alpine halves but live in different files:

- `sh -n` on every shell script (+ `shellcheck` if installed),
- GPT **type GUIDs** consistent between `vbaz.config.psd1` and the provisioner,
- every `VBAZ_*` env var the shell **reads** is **written** by the apkovl
  builder (`Apkovl.ps1`),
- every `@@PLACEHOLDER@@` in `refind.conf.template` is substituted by `Boot.ps1`.

Fast, deterministic, exits non-zero on any failure. This is what CI runs.

## Tier 2 — QEMU + virtual UEFI boot

Builds a GPT disk that mimics the post-Windows-installer state and boots it.

Prereqs (Alpine): `apk add gptfdisk mtools unzip wget qemu-system-x86_64 ovmf`
(Debian/Ubuntu: `gdisk mtools unzip wget qemu-system-x86 ovmf`). User-mode
networking is used, so the guest can reach the Alpine mirror.

```sh
# 1) build the overlay + a virtual UEFI disk (downloads Alpine netboot + rEFInd)
sh test/build-test-disk.sh          # add -v for tracing

# 2) boot it; asserts the provisioner reaches its success marker
sh test/run-smoke.sh --disk test/vbaz-test.img   # add -v for tracing
```

What the disk looks like (see `build-test-disk.sh`) — it models the real
three-role machine (C = Windows, X = host, D = guests):

```
p1 ESP (FAT32)  /EFI/BOOT/BOOTX64.EFI = rEFInd  (stands in for the BCD entry)
                /EFI/vbaz/{refind_x64.efi,vmlinuz-lts,initramfs-lts,modloop-lts,
                          refind.conf, splash.png, drivers_x64/ext4_x64.efi}
                /vbaz.apkovl.tar.gz            (overlay, auto-loaded)
p2 Windows stub Microsoft basic data          (MUST be ignored by the provisioner)
p3 VBAZ_ROOT    tagged, UNFORMATTED           (provisioner formats it — host X:)
p4 VBAZ_ZFS     tagged, UNFORMATTED           (provisioner builds the pool — guests D:)
```

The Windows-stub partition is the point: it verifies the provisioner selects
partitions strictly by GPT type GUID and never touches the untagged one.

**Two-disk variant** (models D: as a separate physical disk):

```sh
ZFS_SEPARATE=1 sh test/build-test-disk.sh
sh test/run-smoke.sh --disk test/vbaz-test.img --disk2 test/vbaz-test-zfs.img
```

`run-smoke.sh` captures the serial console, watches for
`vbaz: provisioning finished OK` / `DONE. Rebooting…`, and uses `-no-reboot`
so QEMU exits when the guest reboots at the end. Full log lands in
`test/last-serial.log`. It uses KVM if `/dev/kvm` is available, else TCG (slow).

### Knobs

- `test/test.env` — the overlay's `vbaz.env`. Default is a light
  `base virt zfs` set for speed; set `VBAZ_PACKAGE_SETS='base virt firecracker
  zfs docker containers kata'` and `VBAZ_KATA_DEVMAPPER='1'` to exercise the
  whole stack (needs more RAM/time).
- `build-test-disk.sh`: `ESP_MB`, `ROOT_MB`, `ZFS_MB`, `OUT`, `REFIND_EFI`
  (skip the download and use a local rEFInd), `VBAZ_VERSION`.
- `run-smoke.sh`: `--timeout`, `--mem`, `--smp`, `--gui`.

### Building just the overlay

`test/build-apkovl.sh` is a portable (Linux) equivalent of the Windows
`Apkovl.ps1`; the disk builder calls it, and you can run it standalone:

```sh
sh test/build-apkovl.sh out.apkovl.tar.gz [vbaz.env]
```

## Limitations / honesty

- No Windows-side coverage (partitioning, `bcdedit`, Secure Boot staging).
- Tier 2 needs network for the in-guest `apk` install; an air-gapped run would
  need a local mirror.
- The `dmsetup`/zvol sector math and Alpine boot params are the parts most
  likely to need tuning on a given kernel/ZFS build — a real Tier-2 run is how
  you find that out before touching hardware.
