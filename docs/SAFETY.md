# v-BAZ safety

Read this before running the installer on any machine whose data you care
about. v-BAZ modifies your partition table and boot configuration. Those are
the two ways to make a computer unbootable or lose data.

## The honest risk list

| Risk | Cause | Mitigation in v-BAZ | You should also |
|---|---|---|---|
| Data loss on the shrunk volume | Resizing NTFS | Uses Windows' own `Resize-Partition`; leaves headroom | **Back up first** |
| Wrong partition formatted | Ambiguous targeting | Formats only the partition with the v-BAZ GPT type GUID; aborts otherwise | Verify `VBAZ_ROOT` size in the plan |
| Windows won't boot | Boot config change | Only *adds* a firmware entry; never edits `bootmgfw.efi` | Know how to reach your firmware boot menu |
| Corruption across dual boot | Fast Startup / hibernation leaves NTFS "dirty" | Pre-flight warns | `powercfg /h off`, reboot |
| Encrypted volume damage | BitLocker + repartition | Pre-flight detects, requires acknowledgement | Suspend BitLocker; keep recovery key |
| Secret exposure | `-SetPassword` writes a transient plaintext file to the (unencrypted) ESP | Shredded on first boot; off by default | Prefer the default first-login password change |
| **Whole-partition wipe** | Converting D: to ZFS, or reusing an existing host partition, **erases it** | Only the GPT-tagged partition; explicit confirmation | **Move anything off D: and the host partition first** |
| MOK key exposure | Secure Boot MOK private key transits the ESP inside the apkovl | Shredded on first boot; key then root-only on ext4 | See `docs/SECUREBOOT.md`; or disable Secure Boot |

## Before you run

1. **Back up.** A full image (or at least your irreplaceable files) — this is
   non-negotiable for a partition operation. **Move everything off the D:
   (ZFS) partition and the host partition — both are erased.**
2. **Know your firmware boot menu key** (often F12/F9/Esc) so you can pick a
   boot entry manually if the added one misbehaves.
3. **Disable Fast Startup / hibernation:** `powercfg /h off`, then reboot.
   Hibernation leaves NTFS in a state that a second OS can corrupt.
4. **BitLocker:** if `C:` is encrypted, either `Suspend-BitLocker -MountPoint
   C: -RebootCount 1` first, or make sure you have the recovery key.
5. **Secure Boot:** stock Alpine kernels and unsigned rEFInd will not load
   under Secure Boot. Plan to disable it, or enroll keys (see
   `TROUBLESHOOTING.md`).
6. **Run `-DryRun`** and read the plan. It performs no destructive action.

## Reversibility

- **Boot entry + ESP files**: fully reversible with `Uninstall-VBaz.ps1`. It
  removes exactly the BCD object v-BAZ created (recorded under
  `%ProgramData%\v-BAZ\bcd-entry.txt`) and the `\EFI\vbaz\` directory + the
  ESP-root apkovl.
- **Partitions**: `Uninstall-VBaz.ps1 -RemovePartitions` deletes the tagged
  Alpine partitions. Reclaiming that space back into `C:` (extend volume) is
  a manual Disk Management step because Windows can only extend into
  *adjacent* free space.
- **The shrink itself** is not auto-undone; you extend `C:` back yourself
  after removing the Alpine partitions.

## The password handling, specifically

By default v-BAZ sets **no** password: the operator account is created and
forced to set a password at first login. This avoids ever writing a secret to
the unencrypted ESP.

If you pass `-SetPassword`, the password you type is written to
`etc/vbaz/secret.pw` inside the apkovl. That file lands on the FAT ESP and
lives there until the first boot, when the provisioner applies it via
`chpasswd` and then `shred`s it. Between install and first boot it is readable
by anyone with physical/administrative access to the ESP. Use the default
unless you understand and accept that window.

## What v-BAZ will refuse to do

- Run on legacy BIOS (no safe firmware-entry mechanism).
- Run without Administrator rights.
- Format a partition it did not create/tag.
- Proceed past low-free-space, or (without acknowledgement) past BitLocker.

## If something goes wrong

- Windows still there but no Alpine entry → `TROUBLESHOOTING.md` §"entry
  missing"; boot Windows normally, re-run or fix the BCD entry.
- Machine boots straight to Windows and you want out → nothing destructive
  happened to Windows; run the uninstaller.
- Neither boots → use your firmware boot menu to select Windows Boot Manager;
  if needed, Windows recovery media `bootrec /rebuildbcd`. Your backup is the
  ultimate fallback — which is why step 1 exists.
