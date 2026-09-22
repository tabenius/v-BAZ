# Ubuntu guest VM

The `guest` package set provisions an **Ubuntu guest** under the host's
libvirt/KVM stack, with a default cloud-init login. It is enabled by default in
`windows/vbaz.config.psd1` (`PackageSets` includes `guest`); drop `guest` from
`PackageSets` to skip it.

## What it does

At first boot the OpenRC service `vbaz-guest` (installed by
`alpine/provision/vbaz-guest.sh`), once `libvirtd` and the ZFS pool are live:

1. ensures the libvirt **default NAT network** is started and autostarts;
2. resolves the **base cloud image** into `/var/lib/vbaz/guest/base.qcow2` — a
   pre-placed qcow2 wins (off-grid); otherwise it downloads `GuestImageUrl`;
3. builds a cloud-init **NoCloud seed ISO** (`xorriso`, volume id `CIDATA`) whose
   `user-data` creates the default user with password auth and passwordless sudo;
4. creates a per-VM qcow2 **overlay** on the base image (`GuestDiskGB`);
5. **`virt-install --import`** defines and starts a headless domain on the
   default network, marked autostart.

State lives on the ZFS dataset `vbaz/guest` → `/var/lib/vbaz/guest`.

## Default login

| Setting | Meaning | Default |
| --- | --- | --- |
| `GuestName` | domain + hostname | `ubuntu` |
| `GuestUser` | default login user | `ragbaz` |
| `GuestPassword` | default password (**change for real use**) | `ragbaz` |
| `GuestImageUrl` | cloud image to fetch online | Ubuntu 24.04 (noble) cloud image |
| `GuestVcpus` / `GuestMemMB` / `GuestDiskGB` | sizing | `2` / `2048` / `20` |

The password is a **default for convenience** — set a strong `GuestPassword`
(or replace the seed's `user-data` with SSH keys) before exposing the guest.
`/etc/vbaz/guest.env` on the host, which carries it, is root-only (`0600`).

## Off-grid note

The Ubuntu cloud image (~600 MB) is **too large for a Windows ESP**, so — unlike
the Rebekah image/model — it is *not* staged there. For an off-grid install,
place the qcow2 at `/var/lib/vbaz/guest/base.qcow2` before first boot (e.g. copy
it onto the ZFS pool), and the service uses it instead of downloading.

## Operating it

```sh
rc-service vbaz-guest status
virsh list --all                 # the 'ubuntu' domain
virsh console ubuntu             # serial console (login: ragbaz)
virsh domifaddr ubuntu           # guest IP on the default NAT network
```

> Alpha, like the rest of v-BAZ. The static wiring is checked in CI
> (`test/check-wiring.sh`); the image fetch, cloud-init seed, and `virt-install`
> launch need confirmation on real hardware or in the QEMU smoke test.
