# v-BAZ

**Install a small Alpine Linux virtualization host — KVM, libvirt, QEMU,
Firecracker, Docker, containerd and Kata on a ZFS guest pool — from inside
Windows, and boot it from the Windows Boot Manager. No USB stick.**

v-BAZ is a Windows-side installer that turns a spare partition into a lean
Alpine host you pick at power-on, with all guest state on a ZFS pool. It's
built as a substrate for microVM / container / hypervisor work (VM-isolated
containers via Kata, Firecracker microVMs, full KVM VMs) beside Windows.

> ⚠️ **Alpha, and it repartitions your disk and can wipe a whole partition.**
> Converting D: to ZFS **destroys its contents**. Back up first, read
> [`docs/SAFETY.md`](docs/SAFETY.md), and test in a VM with a virtual UEFI
> disk before real hardware. Run with `-DryRun` first.

---

## The layout it builds

```
 ESP (shared) │ Windows C: (untouched) │ Alpine host ~15GB ext4 │ Guest pool D: (ZFS)
```

- **Alpine host (~15 GB, ext4)** — OS + tooling only, kept lean.
- **Guest pool (D:, ZFS)** — *all* guest data (VM disks, container layers,
  microVM rootfs), with compression/snapshots. **Its current data is wiped.**

Each role is found by a distinctive **GPT type GUID**, so the Linux side only
ever touches what it owns — never Windows. See
[`docs/DISK-LAYOUT.md`](docs/DISK-LAYOUT.md) and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## What it does (all from Windows)

1. **Pre-flight** — UEFI, Secure Boot, BitLocker, Fast Startup, and validates
   the host partition + the ZFS target.
2. **Partition** — repurposes your existing ~15 GB partition as the Alpine
   host (or shrinks a volume), and tags the large partition for ZFS. Retag +
   un-letter only; the Linux side formats/creates the pool.
3. **Download** — Alpine netboot kernel/initramfs/modloop + rEFInd, verified.
4. **Secure Boot** *(optional)* — generates a MOK, signs rEFInd + the kernel,
   stages a Microsoft-signed shim + MokManager so it boots with Secure Boot
   **on** (one MokManager key-press at first boot). See
   [`docs/SECUREBOOT.md`](docs/SECUREBOOT.md).
5. **Overlay + boot entry** — builds an unattended Alpine `apkovl`, stages the
   ESP files, and adds a **Windows Boot Manager** entry.

On **first boot**, Alpine provisions unattended: installs Alpine onto the host
partition, sets up the KVM/libvirt/QEMU + Firecracker + Docker/containerd +
Kata stack, creates the **ZFS pool** on D: with datasets wired into each
runtime, then flips the boot default to the installed system.

## Requirements

- Windows 10/11 on **UEFI/GPT**; Administrator PowerShell (5.1+ / PowerShell 7).
- An existing ~15 GB partition for the host, and a large partition (D:) you're
  willing to **convert to ZFS** (its data is destroyed).
- Network at first boot; **VT-x/AMD-V** enabled for KVM.
- For Secure Boot: an MS-signed shim (see [`docs/SECUREBOOT.md`](docs/SECUREBOOT.md)),
  otherwise disable Secure Boot in firmware.

## Quick start

```powershell
cd windows
.\Install-VBaz.ps1 -DryRun                      # preview, no changes

# Edit windows\vbaz.config.psd1 (HostDriveLetter, ZfsDriveLetter, sets, ...)

# Real run: host on E:, ZFS on D:, Secure Boot on, prompt for a password:
.\Install-VBaz.ps1 -HostMode existing -HostDriveLetter E -ZfsDriveLetter D `
                   -SecureBoot -SetPassword

# Then reboot, pick "v-BAZ Alpine (KVM host)", and (if Secure Boot) enroll the
# MOK once in MokManager. First boot provisions unattended, then reboots in.
```

Undo the Windows-side changes:

```powershell
.\Uninstall-VBaz.ps1                    # boot entry + ESP files
.\Uninstall-VBaz.ps1 -RemovePartitions  # also delete the tagged partitions
```

## Configuration highlights

`windows/vbaz.config.psd1` (overridable on the command line):

| Setting | Meaning | Default |
|---|---|---|
| `HostMode` / `HostDriveLetter` | `existing` (repurpose a partition) or `shrink` | `existing` |
| `ZfsEnable` / `ZfsDriveLetter` | convert this partition to the ZFS pool (WIPED) | `$true` / `D` |
| `ZfsPoolName` / `ZfsDatasets` | pool name + datasets | `vbaz` / vms,docker,… |
| `SecureBootEnroll` / `ShimSource` | shim+MOK path; where to find shim | `$false` |
| `PackageSets` | `base virt firecracker zfs docker containers kata` | all |
| `Username` / `Hostname` / `Timezone` | Alpine account + host | `operator`/`vbaz`/`UTC` |

## Repository layout

```
windows/  Install-VBaz.ps1, Uninstall-VBaz.ps1, vbaz.config.psd1
  lib/    Common, Preflight, Partition, Download, SecureBoot, Apkovl, Boot
  secureboot/  (drop shimx64.efi + mmx64.efi here for Secure Boot)
alpine/
  provision/  vbaz-provision.sh + vbaz-storage/runtimes/secureboot.sh, packages.list
  overlay/    OpenRC hook that launches the provisioner
  answers/    reference setup-alpine answer file
refind/     rEFInd config template
docs/       ARCHITECTURE, DISK-LAYOUT, SECUREBOOT, SAFETY, TROUBLESHOOTING
```

## Status & honesty

Early alpha. The Windows automation and the GPT-type partition-safety model
are the solid parts. The most likely things to need tuning on real hardware
are isolated with references: **Alpine boot parameters**
(`refind/refind.conf.template`), **`bcdedit` firmware behaviour**
(`windows/lib/Boot.ps1`), and **Kata `kata-fc`/devmapper** wiring
(`docs/DISK-LAYOUT.md`, finished by hand). Shell scripts pass `sh -n`;
PowerShell is reviewed by eye. **Test in a VM first; back up.**

## License

MIT — see [`LICENSE`](LICENSE).
