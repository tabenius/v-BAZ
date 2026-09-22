# v-BAZ — maintainer orientation

v-BAZ installs Alpine Linux (a KVM/QEMU/libvirt + Firecracker + Docker/
containerd/Kata virtualization host) onto its own partition **from inside
Windows**, and boots it from the Windows Boot Manager. See `README.md` for the
user-facing story and `docs/` for the deep dives.

This file is the map for anyone (human or agent) changing the code.

## The two halves and the contract between them

```
Windows side (PowerShell)                 Alpine side (POSIX shell, busybox)
  windows/Install-VBaz.ps1  ── builds ──▶  alpine/provision/vbaz-*.sh
  windows/lib/*.ps1                          run at first boot from the apkovl
        │                                          ▲
        └── writes /etc/vbaz/vbaz.env ─────────────┘  (the ONLY channel between them)
```

The halves never share code; they agree only through **`vbaz.env`**, a file of
`VBAZ_*` variables the Windows apkovl builder writes and the Alpine shell reads.
Three invariants keep them in sync — all enforced by `test/check-wiring.sh`:

1. **Env contract.** Every `VBAZ_*` the shell *reads* must be *written* by
   `windows/lib/Apkovl.ps1`. Add a var → add it in Apkovl.ps1 (and, if the
   smoke test needs it, `test/test.env`).
2. **GPT type GUIDs** must match between `windows/vbaz.config.psd1` and the
   provisioner (partitions are found by type GUID, never by guessing).
3. **`refind.conf.template` placeholders** (`@@X@@`) must all be substituted by
   `windows/lib/Boot.ps1`.
4. **Busybox only.** The Alpine scripts run under busybox `sh`/`sed`/`grep` —
   no GNU-only regex (`\s \w \b`), no bashisms. The wiring check lints for this;
   also validate with `dash -n`.

## Module map

| File | Role |
|---|---|
| `windows/Install-VBaz.ps1` | orchestrator: preflight → partition → download → (Secure Boot) → overlay → boot |
| `windows/lib/Common.ps1` | logging (+ transcript), size parsing, `Test-VBazConfig`, prompts |
| `windows/lib/Preflight.ps1` | UEFI/Secure Boot/BitLocker/space checks; locates the ESP |
| `windows/lib/Partition.ps1` | shrink or repurpose the host partition; tag the ZFS partition |
| `windows/lib/Download.ps1` | Alpine netboot + rEFInd (or offline bundle boot files) |
| `windows/lib/SecureBoot.ps1` | MOK generation, sign rEFInd + kernel, gather shim |
| `windows/lib/Apkovl.ps1` | build the overlay tarball + write `vbaz.env` (the contract) |
| `windows/lib/Boot.ps1` | stage the ESP (with `Assert-VBazEspSpace`), write refind.conf, add the BCD entry |
| `alpine/provision/vbaz-provision.sh` | first-boot driver (find root by GUID, install, flip boot) |
| `alpine/provision/vbaz-{storage,runtimes,thinpool,wifi,secureboot,offline}.sh` | feature modules, sourced by the driver |
| `tools/build-offline-bundle.sh` | build a signed local apk repo for offline first boot (needs `apk`) |
| `test/check-wiring.sh` | the invariants above (CI runs this) |
| `test/build-test-disk.sh` + `run-smoke.sh` | QEMU/UEFI end-to-end (needs qemu/OVMF/sgdisk/mtools) |

## Running the checks

```sh
sh test/check-wiring.sh          # invariants + shell syntax + busybox lint (fast; CI)
for f in alpine/provision/*.sh test/*.sh tools/*.sh; do sh -n "$f"; dash -n "$f"; done
# End-to-end (needs the tools): sh test/build-test-disk.sh && sh test/run-smoke.sh
```

`.github/workflows/wiring.yml` runs the wiring check on every push/PR. There is
no PowerShell in this repo's CI environment; PS changes are reviewed by eye —
keep them PS 5.1-compatible (no `?.`, no ternary) and `Set-StrictMode`-safe.

## Safety rules (do not regress)

- Only ever format/repartition a partition carrying v-BAZ's own GPT **type
  GUID**; the provisioner asserts type + refuses the ESP/NTFS/mounted devices
  before `mkfs`. Windows' `\EFI\Microsoft\` and C: are never touched.
- Both the host partition and the ZFS (D:) partition are **wiped** — the docs
  say so loudly; keep it that way.
- Secrets (account/Wi-Fi passphrase, MOK key) transit the ESP only transiently
  and are shredded on first boot; the persisted forms are hashes/keys.
