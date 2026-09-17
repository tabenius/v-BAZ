# v-BAZ disk layout & guest stack

This describes the three-role disk model and the runtimes that sit on it.

## The three roles

```
 ┌──────────┬───────────────┬───────────────┬──────────────────────────────┐
 │   ESP    │  Windows (C:)  │  Alpine host  │        Guest pool (D:)        │
 │  FAT32   │     NTFS       │  ~15GB ext4   │        ZFS  "vbaz"            │
 │ (shared) │  (untouched)   │  VBAZ_ROOT    │  VBAZ_ZFS  (WIPED → zpool)   │
 └──────────┴───────────────┴───────────────┴──────────────────────────────┘
```

- **Alpine host (~15 GB, ext4)** — the OS and tooling only: kernel, KVM,
  libvirt/QEMU, Firecracker, Docker/containerd, Kata binaries. Kept lean.
- **Guest pool (D:, ZFS)** — *all* stateful guest data. Every runtime's data
  directory is a ZFS dataset mounted into place, so the 15 GB root never fills
  up and you get snapshots/compression/clones for free.

Each partition is found by a distinctive **GPT type GUID**, never by guessing,
so the Linux side only ever formats what it owns (see `docs/ARCHITECTURE.md`).

### Why 15 GB is enough

The host stores no guest images. A minimal Alpine + the full virt/container
stack is ~2–4 GB installed; logs and caches use a little more. Everything that
grows — VM disks, container layers, microVM rootfs, ISOs — lives on ZFS.

If you install the upstream **Kata** static bundle (~300–500 MB under
`/opt/kata`) it still fits comfortably. Watch `df -h /` after first boot.

## ZFS datasets and their mountpoints

The provisioner creates these under the pool (default name `vbaz`) and an
OpenRC service (`vbaz-storage`) mounts them before any runtime starts:

| Dataset | Mounted at | Used by |
|---|---|---|
| `vbaz/vms` | `/var/lib/libvirt/images` | libvirt/QEMU VM disks |
| `vbaz/docker` | `/var/lib/docker` | Docker (ZFS storage driver) |
| `vbaz/firecracker` | `/var/lib/vbaz/firecracker` | Firecracker rootfs + kernels |
| `vbaz/kata` | `/var/lib/vbaz/kata` | Kata images/rootfs |
| `vbaz/images` | `/var/lib/vbaz/images` | shared base images |
| `vbaz/iso` | `/var/lib/vbaz/iso` | install ISOs |

Pool properties: `ashift=12`, `compression=lz4`, `atime=off`, `xattr=sa`,
`acltype=posixacl`, `autotrim=on`. Tune in `alpine/provision/vbaz-storage.sh`.

> **Destructive:** creating the pool erases whatever was on D:. Move anything
> you want to keep off D: first. The pool is created on the installed system's
> *first real boot* (so the ZFS module matches the running kernel exactly).

## The guest stack

One host, `/dev/kvm` shared by everything:

- **Full / lightweight VMs** — libvirt + QEMU/KVM. Disks on `vbaz/vms`. Manage
  with `virsh` / `virt-install`.
- **Firecracker microVMs** — the `firecracker` binary (apk or upstream static).
  Put your guest `vmlinux` + ext4 rootfs on `vbaz/firecracker`. Needs
  `/dev/kvm` (operator is in the `kvm` group).
- **Docker containers** — Docker engine with the **zfs** storage driver, data
  on `vbaz/docker`. `overlay2` is the fallback if ZFS is off.
- **Kata Containers (VM-isolated containers)** — containerd runtime handlers
  `kata-qemu` (default) and `kata-fc` (Firecracker backend). This is the
  natural fit for isolation/containment work: an OCI container that actually
  runs inside a microVM.

### Choosing a runtime

| Need | Use |
|---|---|
| A full OS guest, GUI, kernel dev | libvirt/QEMU VM |
| Fastest cold-start micro sandbox | Firecracker microVM |
| Normal container workflow | Docker / nerdctl |
| Container **with VM isolation** | Kata (`--runtime kata-qemu` / `kata-fc`) |

### Kata + Firecracker (`kata-fc`)

The `kata-fc` handler runs containers inside Firecracker microVMs. It needs
containerd's **devmapper** snapshotter (Firecracker wants block devices, not
overlay). After first boot, configure a devmapper thin-pool (a zvol under
`vbaz` works well) and point containerd at it, then:

```sh
ctr run --runtime io.containerd.run.kata-fc.v2 --snapshotter devmapper \
    docker.io/library/alpine:latest demo sh
```

`kata-qemu` works out of the box with the default snapshotter. Kata install is
best-effort (apk if packaged, else the upstream static bundle under
`/opt/kata`); expect to finish devmapper/`kata-fc` wiring by hand — the pieces
are staged for you.

## Verifying after first boot

```sh
zpool status vbaz && zfs list           # pool + datasets
ls -l /dev/kvm                          # KVM present
rc-service libvirtd status              # VMs
docker info | grep -i 'storage driver'  # should say zfs
containerd --version
firecracker --version
```
