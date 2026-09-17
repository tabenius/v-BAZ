# v-BAZ and Secure Boot (shim + MOK)

v-BAZ can keep **Secure Boot enabled**. It does this the same way every Linux
distro does: a Microsoft-signed **shim** is the first thing UEFI loads, and
shim then trusts a **Machine Owner Key (MOK)** that we generate and sign
everything else with.

The only step that cannot be automated is enrolling the MOK: shim shows the
blue **MokManager** screen at first boot and you confirm the key with a
key-press. That physical confirmation *is* the security boundary — no OS-side
tool can bypass it, by design. Everything else v-BAZ does for you.

## Enable it

```powershell
.\Install-VBaz.ps1 -SecureBoot   # (plus your -HostDriveLetter etc.)
```
or set `SecureBootEnroll = $true` in `vbaz.config.psd1`.

## What the installer does (on Windows)

1. Generates a v-BAZ MOK: a self-signed code-signing certificate
   (`New-SelfSignedCertificate`), exported as `vbaz-mok.cer` (public, DER) and
   `vbaz-mok.pfx` (private key, transient).
2. **Authenticode-signs** rEFInd and the Alpine installer kernel with it
   (`Set-AuthenticodeSignature`). shim validates these PE signatures against
   the enrolled MOK.
3. Stages onto the ESP under `\EFI\vbaz\`:
   - `shimx64.efi` (Microsoft-signed) — the BCD entry points here
   - `mmx64.efi` (MokManager)
   - `grubx64.efi` — the MOK-signed rEFInd (shim's default second stage)
   - `vbaz-mok.cer` — the certificate you enroll
4. Puts the private key into the apkovl so the Alpine provisioner can sign the
   *installed* kernel too.

## What the provisioner does (on Alpine, first boot)

- Signs the installed kernel with the MOK (`sbsign`).
- Moves the key to `/etc/vbaz/mok` on the **ext4 root**, `0600`, and **shreds**
  the copy that was on the ESP.
- Installs `/usr/local/sbin/vbaz-sign-kernel` — run it after a kernel upgrade
  to re-sign and republish the kernel to the ESP.

## The one manual step: enrolling the MOK

1. Reboot and pick the v-BAZ entry. shim loads, sees an untrusted second
   stage, and launches **MokManager**.
2. Choose **Enroll key from disk** (or *Enroll hash* / *Enroll MOK*), browse to
   `\EFI\vbaz\vbaz-mok.cer`, confirm, and reboot.
   (Some shim builds show *Enroll MOK → Continue* if a key is pending.)
3. From then on shim trusts the MOK; rEFInd and the signed kernels boot
   normally under Secure Boot.

## Getting a Microsoft-signed shim

shim itself is MS-signed and, for licensing/format reasons, isn't always
auto-downloadable. Provide it one of these ways:

- Drop `shimx64.efi` + `mmx64.efi` into `windows\secureboot\`, **or**
- Set `ShimSource` in the config to a folder, or a URL of a signed shim
  package (Fedora `shim-x64` RPM, openSUSE `shim`, Ubuntu `shim-signed` DEB,
  or a zip). The installer unpacks rpm/deb/zip with the bundled `tar`
  (libarchive) and finds the binaries.

Extract them yourself from, e.g., a Fedora RPM:
`rpm2cpio shim-x64-*.rpm | cpio -idmv` → `./boot/efi/EFI/fedora/{shimx64,mmx64}.efi`.

## Security notes

- The MOK private key briefly lives inside `vbaz.apkovl.tar.gz` on the
  unencrypted ESP (until first boot removes it). Anyone with physical/admin
  access to the ESP in that window could copy it. For a lab host this is
  usually acceptable; if not, disable Secure Boot instead, or enroll a key you
  generated and kept offline and sign manually.
- The key persists at `/etc/vbaz/mok` so future kernels can be re-signed. Keep
  root access to that host controlled — it is a local signing key.
- This MOK trusts **only** binaries you sign with it; it does not weaken
  Secure Boot for anything else.

## If you'd rather not

Leave `SecureBootEnroll = $false` and disable Secure Boot in firmware. Simpler,
one BIOS toggle, no MokManager step. See `docs/TROUBLESHOOTING.md`.
