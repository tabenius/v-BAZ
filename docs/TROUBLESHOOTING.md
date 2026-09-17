# v-BAZ troubleshooting

## Secure Boot blocks Alpine / rEFInd

Stock Alpine kernels and the plain `refind_x64.efi` are not signed for the
Microsoft UEFI CA, so with Secure Boot on the firmware refuses to load them
(you may see "Access Denied" / "Security Violation").

Options, easiest first:

1. **Disable Secure Boot** in firmware setup (most reliable for a lab host).
2. Use the **signed** rEFInd binary (`refind_x64.efi` under the `signed`
   subfolder of the rEFInd zip is shim-signed) *and* enroll rEFInd's key with
   **MokManager** on first boot. Alpine's kernel still needs to be allowed;
   rEFInd can load an unsigned kernel once its own shim trusts it.
3. Enroll your own keys (advanced).

## The "v-BAZ Alpine" entry doesn't appear in the boot menu

The `bcdedit /copy {bootmgr}` path is firmware-dependent. If your firmware
doesn't surface it:

- Check it exists: `bcdedit /enum firmware` — look for the description you set.
- Some firmwares only show entries they created. Create a real UEFI NVRAM
  entry instead. From a Linux live/rescue environment:
  ```sh
  efibootmgr -c -d /dev/sdX -p <ESP#> -L "v-BAZ Alpine" -l '\EFI\vbaz\refind_x64.efi'
  ```
- Or use your firmware's own boot-menu editor to add
  `\EFI\vbaz\refind_x64.efi` on the ESP.
- As a quick test you can temporarily point the default at rEFInd:
  `bcdedit /set {fwbootmgr} bootsequence {GUID}` (the GUID recorded in
  `%ProgramData%\v-BAZ\bcd-entry.txt`).

## Windows can't shrink the volume enough

`Resize-Partition` fails or the minimum size is close to the current size:
Windows can't move certain files (pagefile, hibernation, restore points,
`$Mft`).

- `powercfg /h off` (removes `hiberfil.sys`), reboot.
- Temporarily disable the pagefile (System → Advanced → Performance →
  Virtual memory), reboot, shrink, re-enable.
- Disable System Restore for the drive, or `vssadmin delete shadows`.
- Defragment (`defrag C: /X` then `/K`) to consolidate free space.
- Reboot and retry.

## First Alpine boot: no network / packages fail

The in-RAM installer pulls `modloop` and packages from the mirror.

- Ensure the machine is on a wired/DHCP network at first boot.
- Wi-Fi is not brought up by the minimal initramfs; use Ethernet for the
  install, configure Wi-Fi afterwards.
- If your mirror is slow/unreachable, set `Mirror` in the config to a closer
  one before installing.
- The provisioner logs to `/var/log/vbaz-provision.log` and mirrors to tty1;
  if it drops to a shell, read that log.

## Boot parameters need tuning for my Alpine release

The Alpine initramfs boot options (`modloop=`, `alpine_repo=`, overlay
discovery, `ip=`) can change between releases. They live in exactly one
place: the `options "…"` line of the first stanza in
`\EFI\vbaz\refind.conf` on the ESP (generated from
`refind/refind.conf.template`). Edit it, save, and re-select the entry.
Reference: <https://wiki.alpinelinux.org/wiki/Boot_options>.

## KVM not available inside Alpine

- Enable **VT-x / AMD-V** (and, for nested use, nested virtualization) in
  firmware.
- Check `ls -l /dev/kvm` and `dmesg | grep -i kvm`. Ensure the `kvm` +
  `kvm_intel`/`kvm_amd` modules are loaded (v-BAZ writes
  `/etc/modules-load.d/kvm.conf`).
- Your user must be in the `kvm` and `libvirt` groups (v-BAZ adds the
  operator account to both); re-login after changes.
- Start libvirt: `rc-service libvirtd start` and
  `rc-update add libvirtd default`.

## Firecracker

If the `firecracker` apk isn't in your Alpine branch, the provisioner fetches
the static release binary into `/usr/local/bin`. For microVMs you still need:
a KVM-capable host (see above), a guest kernel (vmlinux) and a rootfs image.
Firecracker needs `/dev/kvm` access; run it as a user in the `kvm` group or
via the `jailer`.

## Completely undo everything

```powershell
.\Uninstall-VBaz.ps1 -RemovePartitions
```

Then extend `C:` back over the freed space in Disk Management (only works if
the free space is adjacent to `C:`). If the added boot entry lingers, remove
it with `bcdedit /delete {GUID} /f` using the GUID from
`%ProgramData%\v-BAZ\bcd-entry.txt`.
