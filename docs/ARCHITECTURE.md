# v-BAZ architecture

This document explains the boot chain, the partition-safety model, and why
each design choice was made. It is aimed at someone who wants to audit or
extend the installer.

## Goals & constraints

- **No USB stick.** The entire install is driven from Windows; the only
  "media" used is the machine's own ESP and a new partition.
- **Don't endanger Windows.** Never write to Windows' bootloader files,
  never guess which partition to format, keep every change reversible.
- **No toolchain on Windows.** We cannot build GRUB or sign EFI binaries on
  a stock Windows box, so we use *prebuilt* components (rEFInd ships ready
  EFI binaries; Alpine ships netboot kernel/initramfs).

## The boot chain

```
UEFI firmware
   └─ Windows Boot Manager entry  (added by bcdedit, a firmware-class object)
        └─ \EFI\vbaz\refind_x64.efi   (rEFInd, chainloaded)
             ├─ [first boot]  vmlinuz-lts + initramfs-lts  (diskless Alpine)
             │                    → runs the v-BAZ provisioner
             └─ [after install] vmlinuz-lts-installed + root=LABEL=VBAZ_ROOT
```

### Why rEFInd instead of GRUB

Chainloading Linux from the Windows Boot Manager needs an EFI application on
the ESP that (a) can be pointed to from a BCD entry and (b) can load a Linux
kernel with a command line. GRUB would need to be *built* (`grub-mkstandalone`)
or extracted from a distro image — awkward on Windows. rEFInd publishes signed
and unsigned **prebuilt** `refind_x64.efi` binaries plus filesystem drivers
(e.g. `ext4_x64.efi`), and is explicitly designed to be dropped onto an ESP
and chainloaded. Its `refind.conf` gives us a place to set the Linux kernel
command line. That makes it the pragmatic choice for a from-Windows installer.

### Why `bcdedit /copy {bootmgr}`

On UEFI, `{bootmgr}` (the Windows Boot Manager) is a *firmware-class* BCD
object: the firmware itself knows how to present it and load the EFI
application at its `path`. Copying it produces another firmware-class object;
we then repoint the copy's `path` at `\EFI\vbaz\refind_x64.efi` and add it to
`{fwbootmgr} displayorder`. Because it is a firmware entry, UEFI shows it in
the boot menu and loads our EFI binary directly — no need to replace or edit
Windows' own `bootmgfw.efi`.

This is broadly compatible but **firmware-dependent**: some firmwares ignore
BCD-added paths or reorder entries. The fallback is a real UEFI NVRAM entry
(`efibootmgr` from Linux, or the firmware's own boot-menu editor). See
`docs/TROUBLESHOOTING.md`.

## Partition-safety model

The single most dangerous operation is choosing what to format. v-BAZ makes
this deterministic:

1. Windows **creates** the Alpine partition with a fixed GPT **type GUID**
   (`0FC63DAF-…`, "Linux filesystem") and never formats it.
2. The Linux provisioner finds its target by matching that exact GPT type
   GUID (`lsblk -o NAME,PARTTYPE`). If no partition matches, it **aborts** —
   it never falls back to "the biggest free partition" or similar guessing.
3. Only that partition is formatted (`mkfs.ext4 -L VBAZ_ROOT`) and installed
   into. The ESP is mounted read-write only to drop our kernel and edit our
   own `\EFI\vbaz\` subdirectory; Windows' `\EFI\Microsoft\` is never touched.

The same GUID-matching is used by the uninstaller to know which partitions
are safe to delete.

## The unattended provisioner

The Alpine side ships as an **apkovl** (Alpine's local-backup overlay
tarball). The initramfs discovers `vbaz.apkovl.tar.gz` at the ESP root during
its overlay scan and extracts it over the in-RAM system. The overlay:

- enables OpenRC's `local` service (a symlink in `etc/runlevels/default/`),
- drops `etc/local.d/vbaz-provision.start`, which launches
  `etc/vbaz/vbaz-provision.sh`,
- carries `vbaz.env` (config), `packages.list`, and the answer file.

The provisioner (`alpine/provision/vbaz-provision.sh`) does a **controlled
manual install** rather than `setup-disk` on a whole disk, so it only ever
writes the one partition. It then:

- installs `linux-lts` + the selected package sets into the new root,
- configures services, the operator account, KVM module loading, `fstab`,
- copies the installed kernel/initramfs to `\EFI\vbaz\*-installed`,
- edits `refind.conf` to enable and default to the "(installed)" stanza and
  removes the apkovl so provisioning does not repeat.

It is written to be **idempotent**: re-running after a partial failure reuses
an existing `VBAZ_ROOT` and re-applies steps.

## Data flow summary

| Stage | Runs on | Writes to |
|---|---|---|
| Pre-flight, partition, download, boot-setup | Windows | new partition (create only), ESP `\EFI\vbaz\`, BCD |
| First-boot provisioning | Alpine (RAM) | `VBAZ_ROOT` (format+install), ESP `\EFI\vbaz\` (kernel + conf) |
| Steady state | Alpine (installed) | its own root partition only |

## Known-fragile areas (audit these first)

- **Alpine boot parameters** (`refind/refind.conf.template`): `modloop=`,
  `alpine_repo=`, `ip=dhcp`, and overlay auto-discovery differ across Alpine
  releases. Isolated in one template with wiki references.
- **`bcdedit` firmware entry** (`windows/lib/Boot.ps1`): the `device`/`path`
  handling and menu visibility are firmware-dependent.
- **Shrink limits**: Windows may refuse to shrink past unmovable files.
