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

## Off-grid artifact cache (default published versions)

For a **gap-less, off-the-grid install** the mini-cloud needs more than its
apks: it needs the *default versions of the published artifacts* it runs — the
Rebekah image (which bundles OpenCode/Ollama/Sylvae/WeftMark) **and** a default
Ollama model, because Ollama ships **no weights** and offline inference is dead
without one. Those default versions are pinned in
[`tools/artifacts.defaults`](../tools/artifacts.defaults).

Build the cache on a networked host (needs Docker), then hand it to the
installer:

```sh
# Cache the default image + model (pulls the model THROUGH the rebekah image so
# versions/layout match exactly). Override REBEKAH_OLLAMA_MODEL to taste.
sh tools/build-artifact-cache.sh ./offline/rebekah
```

That writes `rebekah-image.tar.gz`, `ollama-model.tar.gz` and a `manifest.env`.
The Windows installer stages them onto the ESP (config `RebekahImageTarball` /
`RebekahModelTarball`, or the `-Offline` bundle's `rebekah/` dir).

At **first boot** the service obtains each artifact, preferring the network and
falling back to the ESP cache:

1. **Image** — pull `REBEKAH_IMAGE` (default `ghcr.io/tabenius/rebekah:latest`)
   via `nerdctl pull --snapshotter devmapper`; on failure, load
   `EFI\<EspSubdir>\rebekah\rebekah-image.tar.gz`.
2. **Model** — if the model store is empty, unpack
   `EFI\<EspSubdir>\rebekah\ollama-model.tar.gz` into Rebekah's Ollama store so
   inference works offline. Online, Ollama just pulls on demand.

The offline bundle builder folds the cache in too:

```sh
VBAZ_REBEKAH_TARBALL=./offline/rebekah/rebekah-image.tar.gz \
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
| `RebekahOllamaModel` | default local model to cache/run | `qwen2.5:0.5b` |
| `RebekahImageTarball` | prebuilt image tarball to bake onto the ESP | `''` |
| `RebekahModelTarball` | prebuilt model tarball to bake onto the ESP | `''` |
| `RebekahGatewayPublish` | publish the authenticated API gateway on the LAN | `$false` |
| `RebekahGatewayPort` | host:container port for the gateway (TLS) | `8443` |
| `RebekahGatewayExpose` | backends reachable through the gateway | `weftmark` |
| `RebekahGatewayToken` | static bearer token (`''` ⇒ per-boot, read it in-VM) | `''` |
| `RebekahGatewayTlsCert` / `RebekahGatewayTlsKey` | PEM cert + key (required to publish) | `''` |
| `RebekahOidcIssuer` / `RebekahOidcAudience` | external SSO for HITL guests | `''` |

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
for governed work.

## Reaching the API on the LAN

Rebekah's four services stay **loopback-only inside the microVM**. The one
authenticated entry point is **`rebekah-gateway`** (see the
[Rebekah repo](https://github.com/tabenius/rebekah)); v-BAZ leaves it loopback by
default and publishes it on the host LAN only when you ask, and only over TLS.

Set `RebekahGatewayPublish = $true` and provide a certificate:

```powershell
RebekahGatewayPublish = $true
RebekahGatewayPort    = 8443
RebekahGatewayExpose  = 'weftmark'                 # add opencode/sylvae/ollama as needed
RebekahGatewayToken   = '<a strong bearer token>'  # internal/LAN/CI clients
RebekahGatewayTlsCert = 'C:\path\rebekah-cert.pem'
RebekahGatewayTlsKey  = 'C:\path\rebekah-key.pem'
# Optional external SSO for human / HITL guests:
RebekahOidcIssuer     = 'https://idp.example.org/'
RebekahOidcAudience   = 'rebekah'
```

The installer bakes the cert + key onto the ESP
(`EFI\<EspSubdir>\rebekah\tls\`). At first boot the service installs them for the
gateway UID (`10005`), writes the gateway config to a **root-only env-file** (so
the token never lands on the host process list), and runs the container with
`--env-file … -p <port>:<port>`. It **fails closed**: publishing with no cert/key
available refuses to start (the gateway would otherwise refuse to bind, and a
token must never cross the wire in the clear).

A client then reaches the board over TLS:

```sh
curl --cacert rebekah-cert.pem \
  -H "Authorization: Bearer $REBEKAH_GATEWAY_TOKEN" \
  https://<host>:8443/weftmark/healthz
```

With no static token set, the gateway mints a per-boot one; read it inside the
microVM with `nerdctl exec rebekah cat /run/rebekah/gateway-token`. For SSO,
send an `Authorization: Bearer <OIDC JWT>` instead. Auth, routing, and the
fail-closed guards are covered in the Rebekah repo's `tests/gateway.sh`.

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
