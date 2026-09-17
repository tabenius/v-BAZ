# v-BAZ

**Install Alpine Linux — with KVM, libvirt and QEMU — onto its own partition
from inside Windows, and boot it from the Windows Boot Manager. No USB stick.**

v-BAZ is a Windows-side installer that carves out a partition, stages a
minimal Alpine system, and registers a UEFI boot entry so you can pick
*"v-BAZ Alpine"* at power-on and land in a lean virtualization host. It is
built as a substrate for microVM / hypervisor work (KVM + QEMU + libvirt,
optionally Firecracker) alongside an existing Windows install.

> ⚠️ **This is alpha, and it repartitions your system disk.**
> Repartitioning and editing the boot configuration can make a machine
> unbootable or destroy data. **Take a full backup first**, and read
> [`docs/SAFETY.md`](docs/SAFETY.md). Test on a spare machine or a VM with a
> virtual UEFI disk before running on hardware you care about. Run with
> `-DryRun` first.

---

## What it does

Everything below runs from an elevated PowerShell prompt on Windows — no USB
media, no manual `setup-alpine` typing.

1. **Pre-flight** — verifies UEFI firmware, checks Secure Boot, free space,
   BitLocker and Fast Startup, and locates your EFI System Partition (ESP).
2. **Partition** — shrinks a chosen NTFS volume and creates a dedicated
   Alpine root partition (and optional swap), tagged with a distinctive GPT
   type GUID so the Linux side can find *exactly* its own partition and never
   touch Windows. The partition is left unformatted (Windows can't make ext4;
   Alpine formats it on first boot).
3. **Download** — fetches the Alpine *netboot* kernel/initramfs/modloop and
   the prebuilt **rEFInd** EFI bootloader, verifying checksums.
4. **Overlay** — builds an Alpine `apkovl` carrying an unattended
   *provisioner* plus your configuration.
5. **Boot integration** — copies the files onto the ESP, writes a
   `refind.conf`, and adds a **Windows Boot Manager** entry (via `bcdedit`,
   by copying the firmware `{bootmgr}` object and repointing it at rEFInd).

On the **first boot** into the new entry, Alpine comes up in RAM, runs the
provisioner, and:

- formats `VBAZ_ROOT` and installs a minimal Alpine *sys* system onto it,
- installs the KVM / libvirt / QEMU stack (and, if selected, Firecracker),
- creates an operator account (in the `kvm`/`libvirt` groups), enables
  services, writes `fstab`,
- copies the installed kernel to the ESP and flips the boot default to the
  installed system.

Subsequent boots go straight into your persistent Alpine KVM host.

## Requirements

- Windows 10/11 on **UEFI/GPT** (legacy BIOS is not supported).
- Administrator PowerShell (5.1+ or PowerShell 7).
- Free space on an NTFS volume for the Alpine root (default 40 GB) + headroom.
- A network connection at first Alpine boot (packages are pulled from a mirror).
- Ideally **Secure Boot disabled** (stock Alpine/rEFInd aren't Microsoft-signed;
  see [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)).
- CPU virtualization (VT-x/AMD-V) enabled in firmware for KVM.

## Quick start

```powershell
# From an ELEVATED PowerShell, in the repo root:
cd windows

# 1) Preview the plan — makes NO changes:
.\Install-VBaz.ps1 -DryRun

# 2) Edit windows\vbaz.config.psd1 (drive letter, sizes, packages, ...)

# 3) Real run (example: 60 GB root on C:, prompt for an account password):
.\Install-VBaz.ps1 -ShrinkDriveLetter C -AlpineRootSize 60GB -SetPassword

# 4) Reboot and choose "v-BAZ Alpine (KVM host)" from the boot menu.
#    Watch the first boot — it provisions unattended, then reboots into
#    the installed system.
```

To undo the Windows-side changes (boot entry + ESP files; keeps the
partition unless you ask):

```powershell
.\Uninstall-VBaz.ps1                    # remove boot entry + ESP files
.\Uninstall-VBaz.ps1 -RemovePartitions  # also delete VBAZ_ROOT/VBAZ_SWAP
```

## Configuration

All defaults live in [`windows/vbaz.config.psd1`](windows/vbaz.config.psd1)
and can be overridden on the command line. Highlights:

| Setting | Meaning | Default |
|---|---|---|
| `ShrinkDriveLetter` | NTFS volume to shrink | `C` |
| `AlpineRootSize` | Size of the Alpine root partition | `40GB` |
| `AlpineSwapSize` | Swap partition (`0` = swapfile instead) | `4GB` |
| `AlpineBranch` / `AlpineVersion` | Alpine release to install | `v3.21` / `3.21.0` |
| `PackageSets` | `base`, `virt`, `firecracker` | all three |
| `Username` / `Hostname` | Alpine operator account / hostname | `operator` / `vbaz` |

## Repository layout

```
windows/            Windows-side installer (runs here)
  Install-VBaz.ps1    orchestrator
  Uninstall-VBaz.ps1  reverse the changes
  vbaz.config.psd1    configuration
  lib/                Common, Preflight, Partition, Download, Apkovl, Boot
alpine/             Linux-side, packed into the apkovl
  provision/          first-boot provisioner + package manifest
  overlay/            OpenRC hook that launches the provisioner
  answers/            reference setup-alpine answer file
refind/             rEFInd config template (boot parameters)
docs/               ARCHITECTURE, SAFETY, TROUBLESHOOTING
```

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how the boot chain and the
  partition-safety model work, and why each choice was made.
- [`docs/SAFETY.md`](docs/SAFETY.md) — the risks, the reversibility model, and
  what to back up.
- [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — Secure Boot, the boot
  entry not appearing, shrink failures, boot-parameter tuning, and the manual
  fallback.

## Status & honesty

This is an early, opinionated scaffold. The Windows automation and the
partition-safety model are the solid parts. The exact **Alpine boot
parameters** and the **`bcdedit` firmware-entry behaviour** vary by firmware
and Alpine release and are the most likely things to need tuning on your
hardware — they are deliberately isolated in
[`refind/refind.conf.template`](refind/refind.conf.template) and
[`windows/lib/Boot.ps1`](windows/lib/Boot.ps1) with references. Please test in
a VM first and file issues with your firmware/Alpine details.

## License

MIT — see [`LICENSE`](LICENSE).
