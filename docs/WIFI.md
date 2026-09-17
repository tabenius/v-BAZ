# v-BAZ on a Wi-Fi-only machine (no Ethernet)

There are **two** separate network needs, and they have different answers.

## 1. The one-time first-boot install — needs connectivity *then*

On the first boot, Alpine comes up in RAM (from the netboot kernel/initramfs on
the ESP) and **downloads packages from a mirror** to build the host. That
minimal netboot environment does **not** contain a Wi-Fi stack — no
`wpa_supplicant`, and usually not your card's driver/firmware — so Wi-Fi can't
reliably come up that early.

**Reliable options for the install (pick one):**

- **USB phone tether** — plug your phone in via USB and enable USB tethering
  (RNDIS/CDC-Ethernet). It appears as a *wired* interface, so `ip=dhcp` just
  works. Nothing to configure. Easiest.
- **USB-Ethernet dongle** — same idea; shows up as a normal wired NIC.
- Any Ethernet for ~10 minutes while the install runs.

v-BAZ *does* make a best-effort Wi-Fi attempt at this stage (if you set the
Wi-Fi options below), but it only succeeds when the netboot environment happens
to already have `wpa_supplicant` + the driver + firmware — so treat the tether/
dongle as the expected path for the first install. If there's no connectivity,
the provisioner stops early with a clear message rather than half-installing.

> Want a truly offline first boot (no tether at all)? That needs the Wi-Fi
> bootstrap packages + firmware staged on the ESP as a local apk repo. It's a
> bigger change — ask and I can add it.

## 2. The installed host afterward — native Wi-Fi

This part v-BAZ configures for you. Set the Wi-Fi options and, during the
(tethered) install, it installs `wpa_supplicant` + `wireless-regdb` + firmware
into the host, writes `wpa_supplicant.conf` (with the **hashed** PSK — the
plaintext is shredded), sets up `wlan0`/DHCP, and enables the service. After
that one install, the machine connects over Wi-Fi on its own.

### Configure it

In `windows/vbaz.config.psd1` (or on the command line):

```powershell
.\Install-VBaz.ps1 -HostMode existing -HostDriveLetter X -ZfsDriveLetter D `
    -WifiSSID "your-ssid" -SetWifiPassword
# (also set WifiCountry, e.g. 'SE', and narrow WifiFirmware to your chip)
```

| Setting | Meaning |
|---|---|
| `WifiSSID` / `-WifiSSID` | your network name (empty = skip Wi-Fi setup) |
| `-SetWifiPassword` | prompts for the passphrase (never stored in config) |
| `WifiCountry` | regulatory domain, e.g. `US`, `SE`, `DE` |
| `WifiFirmware` | firmware apk; `linux-firmware` (all) or narrow it, e.g. `linux-firmware-iwlwifi` (Intel), `linux-firmware-ath10k_pci` (Qualcomm), `linux-firmware-brcm` (Broadcom) |

### Notes

- The passphrase transits the ESP transiently inside the apkovl and is shredded
  on first boot; the persisted config keeps only the wpa_passphrase hash.
- Find your firmware package for your chip with `lspci -k` / `lsmod` once the
  host is up, and adjust `WifiFirmware` to keep the 15 GB host lean.
- If `wlan0` doesn't come up after install, check
  `rc-service wpa_supplicant status`, `dmesg | grep -i firmware`, and
  `iw dev` — the driver/firmware for your card is the usual culprit.
