# windows/secureboot

Drop a **Microsoft-signed shim** here to enable Secure Boot without editing
the config:

- `shimx64.efi`
- `mmx64.efi`  (MokManager)

The installer also accepts a folder or a package URL via the config's
`ShimSource` (Fedora `shim-x64` RPM, openSUSE `shim`, Ubuntu `shim-signed`
DEB, or a zip). See [`../../docs/SECUREBOOT.md`](../../docs/SECUREBOOT.md).

These `.efi` binaries are **not** committed to the repo (see `.gitignore`) —
supply your own from a trusted, signed source.
