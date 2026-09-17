# assets/original — RAGBAZ / v-BAZ boot splash

Original artwork for the boot splash shown by rEFInd when loading the distro.

- `vbaz-splash.png` — the composed 1920×1080 splash (this is what boots).
- `splash-720.png` — a 720p copy.
- `background.png` — the procedural ink-wash (shan shui) rice-paper scene.
- `badges.png` — the honeycomb of hex badges (original glyphs + labels).
- `make-splash.py` — regenerates all of the above (`python3 make-splash.py`,
  needs `Pillow`).

Everything here is **original**: the mountains, mist, trees, rocky pool and
koi are procedurally drawn; the badge glyphs are generic shapes, not the
upstream project logos.

**Use your own art:** drop a `background.png` and/or `badges.png` into this
folder and re-run `make-splash.py` — if those files exist they're used as-is
instead of the procedural originals, and only the RAGBAZ / v-BAZ branding is
composited on top.

## How it reaches the screen

`windows/lib/Boot.ps1` copies `vbaz-splash.png` to the ESP as
`\EFI\<subdir>\splash.png`, and `refind/refind.conf.template` sets it as the
rEFInd `banner` (`banner_scale fillscreen`). The smoke-test disk
(`test/build-test-disk.sh`) stages it too.
