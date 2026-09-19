# Rebekah — the default AI orchestration / governance platform

v-BAZ ships **[Rebekah](https://github.com/tabenius/rebekah)** as its default AI
orchestration and governance layer. Rebekah is a self-contained OCI image that
supervises four services under one process — **OpenCode** (agent sessions),
**Ollama** (local inference), **Sylvae** (skill execution + run evidence) and
**WeftMark** (coordination, provenance, evidence, review) — with a fail-closed
**Ephor/KAGP** governance connector. On v-BAZ it runs **inside a Kata
Firecracker microVM**, so the whole platform is VM-isolated on top of the
microVM/hypervisor substrate v-BAZ builds.

## How it is wired

When the `rebekah` package set is enabled (it is, by default), the first-boot
provisioner (`alpine/provision/vbaz-rebekah.sh`) installs an OpenRC service and
keeps all Rebekah state on the ZFS pool:

| Piece | Where |
| --- | --- |
| Service | `/etc/init.d/rebekah` (runlevel `default`, after `containerd`, `vbaz-storage`, `vbaz-thinpool`) |
| Config | `/etc/vbaz/rebekah.env` (`REBEKAH_IMAGE`, `REBEKAH_RUNTIME`, `REBEKAH_SNAPSHOTTER`, …) |
| State | ZFS dataset `vbaz/rebekah` → `/var/lib/vbaz/rebekah/{state,workspace}` |
| Runtime | `io.containerd.kata-fc.v2` (Kata + Firecracker), `devmapper` snapshotter |

The service runs the container with the least-privilege posture Rebekah
documents: `--read-only`, `--cap-drop ALL` plus only `CHOWN, DAC_OVERRIDE,
SETUID, SETGID, KILL`, `--security-opt no-new-privileges`, and loopback-only
ports — now wrapped in a Firecracker microVM as well.

## Image delivery (registry pull, ESP-staged fallback)

Rebekah is a Nix-built image, so the service obtains it at **first boot** (when
containerd, the ZFS pool and the devmapper thin-pool are live), in this order:

1. **Pull** `REBEKAH_IMAGE` (default `ghcr.io/tabenius/rebekah:latest`) via
   `nerdctl pull --snapshotter devmapper`.
2. **Fallback:** if the pull fails (offline / air-gapped), load a tarball staged
   on the ESP at `EFI\<EspSubdir>\rebekah\rebekah-image.tar.gz`.

Stage that tarball either by setting `RebekahImageTarball` in
`windows/vbaz.config.psd1` (the Windows installer copies it to the ESP), or by
building it into the offline bundle:

```sh
# produce a rebekah image tarball from its flake, then:
VBAZ_REBEKAH_TARBALL=/path/to/rebekah-image.tar.gz \
    sh tools/build-offline-bundle.sh ./offline
```

## Configuration

`windows/vbaz.config.psd1`:

| Setting | Meaning | Default |
| --- | --- | --- |
| `PackageSets` includes `rebekah` | enable the platform | on |
| `ZfsDatasets` includes `rebekah` | dataset for its state | on |
| `RebekahImage` | image ref to pull | `ghcr.io/tabenius/rebekah:latest` |
| `RebekahRuntime` | containerd runtime handler | `io.containerd.kata-fc.v2` |
| `RebekahSnapshotter` | snapshotter (kata-fc needs devmapper) | `devmapper` |
| `RebekahImageTarball` | prebuilt tarball to bake onto the ESP | `''` |

To run Rebekah as an ordinary container instead of a microVM, set
`RebekahRuntime = ''` (use the default runc runtime) and
`RebekahSnapshotter = 'overlayfs'`. To disable it entirely, drop `rebekah` from
`PackageSets`.

## Operating it

```sh
rc-service rebekah status
nerdctl ps                       # the 'rebekah' container / microVM
nerdctl logs -f rebekah
```

The service seeds an empty Git workspace at `/var/lib/vbaz/rebekah/workspace`
(WeftMark requires a repo with a `HEAD`); mount or push a real repository there
for governed work. Rebekah's own ports are loopback-only inside the microVM —
reach them through a deliberate proxy, never by publishing them.

## Governance

WeftMark provides the coordination/evidence/review ledger; the Ephor/KAGP
connector attaches governance decisions as typed evidence and **fails closed**
when the governance endpoint is unavailable. Point it at a governance-http
bridge with `EPHOR_URL` (passed into the container) when you run KAGP alongside
v-BAZ. See the [Rebekah repo](https://github.com/tabenius/rebekah) for the full
runtime contract and security invariants.

> Alpha, like the rest of v-BAZ. The static wiring is checked in CI
> (`test/check-wiring.sh`); confirm the microVM launch on real hardware or in
> the QEMU smoke test before trusting it for production work.
