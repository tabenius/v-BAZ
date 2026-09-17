# v-BAZ fully-offline first boot (no tether)

The normal first boot downloads packages from the Alpine mirror, so on a
Wi-Fi-only machine it needs a temporary wire (see `docs/WIFI.md`). **Offline
mode removes that**: you pre-build a bundle with a complete local apk
repository, stage it on the ESP, and the first boot installs from it with **no
network at all** — then brings Wi-Fi up from those same offline packages so the
installed host is online afterwards.

> ⚠️ Experimental. The local-apk install is deterministic, but the local
> modloop mount and in-RAM Wi-Fi bring-up are the parts to confirm on real
> hardware or in the QEMU smoke test before trusting it.

## Step 1 — build the bundle (needs `apk`)

`apk` only runs on Alpine, so build the bundle there or in a container/WSL.
From any OS with Docker:

```sh
docker run --rm -v "$PWD/offline:/out" -v "$PWD:/repo" alpine:3.21 \
    sh /repo/tools/build-offline-bundle.sh /out
```

On an Alpine box: `doas sh tools/build-offline-bundle.sh ./offline`

Knobs (env): `VBAZ_BRANCH`, `VBAZ_ARCH`, `VBAZ_FLAVOR`,
`VBAZ_WIFI_FIRMWARE` (narrow to your chip to shrink the bundle — the full
`linux-firmware` is large). Output:

```
offline/boot/{vmlinuz-lts,initramfs-lts,modloop-lts}
offline/apks/<arch>/{*.apk,APKINDEX.tar.gz}   # signed local repo
offline/keys/<name>.rsa.pub                    # repo public key
offline/bundle.env
```

Copy the `offline/` directory to the Windows machine.

## Step 2 — install offline

```powershell
.\Install-VBaz.ps1 -HostMode existing -HostDriveLetter X -ZfsDriveLetter D `
    -Offline C:\path\to\offline `
    -WifiSSID "your-ssid" -SetWifiPassword
```

The installer stages the bundle's boot files + the signed apk repo + its key
onto the ESP, and marks the boot as offline (`nomodloop`, no network params).
rEFInd itself is still fetched over the network unless a `refind_x64.efi` is
found inside the bundle (the Windows box has connectivity; only the *Alpine*
first boot is offline).

## What the first boot does (offline)

1. Mounts the ESP, points apk at the local repo, and trusts its signing key.
2. Mounts the ESP-staged **modloop** so Wi-Fi/ZFS drivers are available in the
   in-RAM installer (the netboot initramfs carries only a minimal set).
3. Installs the whole stack (base + virt + ZFS + Docker/containerd + …) from
   the **local** repo — no mirror.
4. Installs the Wi-Fi stack from the local repo and associates, so the host is
   online. If Wi-Fi doesn't come up, the install still completes; the host is
   simply offline until you configure Wi-Fi.
5. Repoints the installed system's apk repos at the online mirror so it can
   update later over Wi-Fi.

## Limits

- Kata / Firecracker fetch upstream static binaries over the network; offline,
  those steps are skipped (best-effort) unless the packages are in your branch.
  Everything else installs from the bundle.
- Keep the bundle's Alpine branch/arch/flavor matching the installer config.
- The bundle can be large (mostly firmware); narrow `VBAZ_WIFI_FIRMWARE`.
