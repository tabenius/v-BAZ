#!/usr/bin/env python3
"""
v-BAZ / RAGBAZ boot splash generator.

Composes an original boot splash:
  * background: an ink-wash (shan shui) rice-paper scene - misty mountains,
    drifting clouds, tree silhouettes, and a rocky pool with subtle koi.
    Entirely procedural / original artwork.
  * foreground: a honeycomb of hex badges (original glyphs + component labels).
  * branding: RAGBAZ wordmark + v-BAZ tagline.

Bring your own art: if assets/original/background.png and/or badges.png exist,
they are used instead of the procedural originals. Drop your files there and
re-run:  python3 assets/original/make-splash.py

Outputs (assets/original/): background.png, badges.png, vbaz-splash.png (1920x
1080), splash-720.png.
"""
import os, random
from math import cos, sin, radians
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 1920, 1080
random.seed(20260917)

# --- palette ---------------------------------------------------------------
PAPER   = (236, 226, 202)      # warm xuan-paper cream (also badge cutouts)
PAPER_D = (223, 210, 181)
INK     = (28, 26, 24)         # sumi ink
HERO_INK = (34, 30, 26)
CINNABAR = (176, 53, 43)       # seal red accent
WHITE   = (247, 243, 232)

BADGES = [
    ("ALPINE",           (46, 166, 240),  (150, 214, 255)),
    ("WEFTMARK",         (26, 163, 163),  (120, 224, 224)),
    ("SYLVAE",           (122, 192, 67),  (196, 235, 150)),
    ("EPHOR",            (245, 178, 26),  (255, 224, 140)),
    ("QEMU·KVM·LIBVIRT", (176, 53, 154),  (232, 150, 214)),
]

FONTDIRS = ["/mnt/skills/examples/canvas-design/canvas-fonts",
            "/usr/share/fonts/truetype/dejavu"]


def font(names, size):
    for d in FONTDIRS:
        for n in names:
            p = os.path.join(d, n)
            if os.path.exists(p):
                return ImageFont.truetype(p, size)
    return ImageFont.load_default()


F_HERO  = font(["BigShoulders-Bold.ttf", "DejaVuSans-Bold.ttf"], 250)
F_TAG   = font(["GeistMono-Bold.ttf", "DejaVuSansMono-Bold.ttf"], 46)
F_SUB   = font(["GeistMono-Regular.ttf", "DejaVuSansMono.ttf"], 34)
F_LABEL = font(["DejaVuSans-Bold.ttf"], 30)


# ---------------------------------------------------------------------------
# Background: ink-wash rice-paper scene
# ---------------------------------------------------------------------------
def _ridge(y, amp, rough, n=48):
    """A jagged mountain ridge polyline across the width."""
    pts, x = [], 0
    step = W / n
    h = y
    for i in range(n + 1):
        h += random.uniform(-amp, amp) * (0.4 + rough)
        h = max(y - amp * 2, min(y + amp * 1.2, h))
        pts.append((x, h))
        x += step
    return pts


def _wash(color, alpha, blur):
    """Return an (image, draw) pair for a translucent ink wash layer."""
    lyr = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    return lyr, ImageDraw.Draw(lyr), color + (alpha,), blur


def make_background():
    img = Image.new("RGB", (W, H), PAPER)

    # 1) paper fibre / speckle + gentle tone drift
    d = ImageDraw.Draw(img, "RGBA")
    for _ in range(2600):
        x, y = random.randint(0, W), random.randint(0, H)
        c = PAPER_D if random.random() < 0.7 else (250, 245, 232)
        d.line([(x, y), (x + random.randint(1, 6), y + random.randint(-1, 1))],
               fill=c + (40,), width=1)
    # soft warm vignette
    vig = Image.new("L", (W, H), 0)
    ImageDraw.Draw(vig).ellipse([-W * 0.2, -H * 0.25, W * 1.2, H * 1.25], fill=60)
    vig = vig.filter(ImageFilter.GaussianBlur(220))
    img = Image.composite(img, Image.new("RGB", (W, H), (206, 192, 160)), vig)

    base = img.convert("RGBA")

    # 2) distant mountain ranges (far = pale blue-grey, near = darker ink)
    ranges = [
        (330, 150, (150, 158, 158), 70, 5),
        (430, 175, (118, 128, 130), 95, 4),
        (545, 205, (78, 90, 94),   120, 3),
    ]
    for y, amp, col, alpha, blur in ranges:
        lyr = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ld = ImageDraw.Draw(lyr)
        ridge = _ridge(y, amp, 0.6)
        ld.polygon(ridge + [(W, H), (0, H)], fill=col + (alpha,))
        lyr = lyr.filter(ImageFilter.GaussianBlur(blur))
        base.alpha_composite(lyr)

    # 3) drifting cloud / mist bands
    for cy, ch, a in [(300, 60, 150), (400, 80, 130), (500, 70, 120), (600, 90, 110)]:
        band = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        bd = ImageDraw.Draw(band)
        for _ in range(14):
            x = random.randint(-100, W)
            w = random.randint(240, 620)
            yy = cy + random.randint(-25, 25)
            hh = random.randint(int(ch * 0.5), ch)
            bd.ellipse([x, yy, x + w, yy + hh], fill=(248, 244, 234, a))
        band = band.filter(ImageFilter.GaussianBlur(28))
        base.alpha_composite(band)

    # 4) the rocky pool (lower third): a pale water plane + rocks + ripples
    pool = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    pd = ImageDraw.Draw(pool)
    pd.ellipse([-200, 760, W + 200, 1180], fill=(198, 200, 190, 150))
    pool = pool.filter(ImageFilter.GaussianBlur(18))
    base.alpha_composite(pool)
    d2 = ImageDraw.Draw(base, "RGBA")
    for _ in range(22):                      # water ripples
        x = random.randint(150, W - 150); y = random.randint(820, 1060)
        w = random.randint(60, 220)
        d2.arc([x, y, x + w, y + 22], 200, 340, fill=(120, 130, 130, 70), width=2)
    for rx, ry, rw, rh in [(120, 900, 260, 150), (1560, 860, 300, 170),
                           (760, 1010, 220, 120)]:   # rocks (ink blobs)
        rock = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(rock).ellipse([rx, ry, rx + rw, ry + rh], fill=(54, 58, 58, 190))
        rock = rock.filter(ImageFilter.GaussianBlur(6))
        base.alpha_composite(rock)

    # 5) koi in the pool (subtle, kept clear of the centre text band)
    for kx, ky, ang in [(330, 985, -22), (1560, 955, 205), (250, 1050, 20)]:
        _koi(base, kx, ky, ang)

    # 6) tree silhouettes flanking the scene (original literati style)
    _pine(base, 250, 690, 230, 0.9)
    _pine(base, 150, 720, 180, 0.7)
    _bare_tree(base, 1700, 700, 250)
    _bare_tree(base, 1810, 740, 190)

    # 7) a faint deckle border
    bd = ImageDraw.Draw(base, "RGBA")
    bd.rectangle([26, 26, W - 26, H - 26], outline=(120, 108, 84, 90), width=2)

    return base.convert("RGB")


def _koi(base, x, y, ang):
    """A small stylised koi: pale body with soft orange patches and a fan tail."""
    a = radians(ang)
    dx, dy = cos(a), sin(a)
    px, py = -dy, dx
    body = (243, 238, 226)
    patch = (216, 104, 52)
    lyr = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(lyr)
    L, Wd = 74, 26
    head = (x + dx * L * .5, y + dy * L * .5)
    tail = (x - dx * L * .5, y - dy * L * .5)
    # tapered body via a smooth polygon (round head, narrow tail)
    d.polygon([
        (head[0], head[1]),
        (x + px * Wd * .5, y + py * Wd * .5),
        (tail[0] + px * Wd * .16, tail[1] + py * Wd * .16),
        (tail[0] - px * Wd * .16, tail[1] - py * Wd * .16),
        (x - px * Wd * .5, y - py * Wd * .5),
    ], fill=body + (165,))
    # two soft orange patches
    for t in (0.16, -0.12):
        cxp = x + dx * L * t
        cyp = y + dy * L * t
        d.ellipse([cxp - 11, cyp - 9, cxp + 11, cyp + 9], fill=patch + (150,))
    # fan tail
    tb = (tail[0] - dx * 22, tail[1] - dy * 22)
    d.polygon([tail, (tb[0] + px * 17, tb[1] + py * 17),
               (tb[0] - px * 17, tb[1] - py * 17)], fill=body + (120,))
    lyr = lyr.filter(ImageFilter.GaussianBlur(1.1))
    base.alpha_composite(lyr)


def _pine(base, x, y, h, scale):
    lyr = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(lyr)
    ink = (34, 40, 40, 210)
    d.line([(x, y), (x, y - h)], fill=ink, width=int(10 * scale))
    tiers = 5
    for i in range(tiers):
        ty = y - h * (0.25 + 0.62 * i / tiers)
        tw = (h * 0.42) * (1 - i / (tiers + 1)) * scale
        d.polygon([(x - tw, ty), (x + tw, ty), (x, ty - h * 0.2 * scale)], fill=ink)
    lyr = lyr.filter(ImageFilter.GaussianBlur(1.0))
    base.alpha_composite(lyr)


def _bare_tree(base, x, y, h):
    lyr = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(lyr)
    ink = (30, 30, 30, 205)

    def branch(x0, y0, ang, length, w):
        if length < 14 or w < 1:
            return
        x1 = x0 + cos(radians(ang)) * length
        y1 = y0 - sin(radians(ang)) * length
        d.line([(x0, y0), (x1, y1)], fill=ink, width=max(1, int(w)))
        branch(x1, y1, ang + random.uniform(14, 34), length * 0.72, w * 0.7)
        branch(x1, y1, ang - random.uniform(14, 34), length * 0.72, w * 0.7)

    branch(x, y, 90, h * 0.42, 11)
    lyr = lyr.filter(ImageFilter.GaussianBlur(0.8))
    base.alpha_composite(lyr)


# ---------------------------------------------------------------------------
# Foreground: hex badges (original glyphs)
# ---------------------------------------------------------------------------
def hexpoints(cx, cy, r):
    return [(cx + r * cos(radians(60 * i)), cy + r * sin(radians(60 * i))) for i in range(6)]


def glyph(d, name, cx, cy, s):
    ink = INK
    if name == "ALPINE":
        d.polygon([(cx - s, cy + s * .55), (cx - s * .25, cy - s * .6),
                   (cx + s * .15, cy + s * .05), (cx + s * .45, cy - s * .35),
                   (cx + s, cy + s * .55)], fill=ink)
    elif name == "WEFTMARK":
        w = int(s * .34)
        d.line([(cx - s * .7, cy - s * .5), (cx + s * .7, cy + s * .5)], fill=ink, width=w)
        d.line([(cx + s * .7, cy - s * .5), (cx - s * .7, cy + s * .5)], fill=ink, width=w)
        d.ellipse([cx - w * .5, cy - w * .5, cx + w * .5, cy + w * .5], fill=ink)
    elif name == "SYLVAE":
        d.rectangle([cx - s * .12, cy, cx + s * .12, cy + s * .75], fill=ink)
        for dx, dy, rr in [(-.35, -.15, .34), (.35, -.15, .34), (0, -.5, .42),
                           (-.15, .12, .3), (.2, .1, .3)]:
            d.ellipse([cx + dx * s - rr * s, cy + dy * s - rr * s,
                       cx + dx * s + rr * s, cy + dy * s + rr * s], fill=ink)
    elif name == "EPHOR":
        d.ellipse([cx - s, cy - s * .55, cx + s, cy + s * .55], fill=ink)
        d.ellipse([cx - s * .78, cy - s * .42, cx + s * .78, cy + s * .42], fill=PAPER)
        d.ellipse([cx - s * .34, cy - s * .34, cx + s * .34, cy + s * .34], fill=ink)
        d.ellipse([cx - s * .12, cy - s * .12, cx + s * .12, cy + s * .12], fill=WHITE)
        d.polygon([(cx - s * .3, cy + s * .5), (cx + s * .3, cy + s * .5), (cx, cy + s * .95)], fill=ink)
    elif name.startswith("QEMU"):
        for dx, dy in [(.28, -.28), (0, 0)]:
            x0, y0 = cx - s * .78 + dx * s, cy - s * .6 + dy * s
            x1, y1 = x0 + s * 1.2, y0 + s * 1.0
            d.rounded_rectangle([x0, y0, x1, y1], radius=s * .12, fill=ink)
            d.rounded_rectangle([x0 + 6, y0 + s * .26, x1 - 6, y1 - 6], radius=s * .08, fill=PAPER)
        d.rectangle([cx - s * .18, cy + s * .05, cx + s * .18, cy + s * .4], fill=ink)


def make_badges():
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = 175
    dx = r * 1.74
    dy = r * 1.5
    cx0, cy0 = W / 2, H / 2 + 30
    pos = [(cx0 - dx / 2, cy0 - dy / 2), (cx0 + dx / 2, cy0 - dy / 2),
           (cx0 - dx, cy0 + dy / 2), (cx0, cy0 + dy / 2), (cx0 + dx, cy0 + dy / 2)]
    for (label, fill, edge), (cx, cy) in zip(BADGES, pos):
        glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(glow).polygon(hexpoints(cx, cy, r + 14), fill=edge + (150,))
        img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(12)))
        d.polygon(hexpoints(cx, cy, r), fill=fill + (255,))
        d.line(hexpoints(cx, cy, r) + [hexpoints(cx, cy, r)[0]], fill=edge + (255,), width=6)
        d.line(hexpoints(cx, cy, r - 12) + [hexpoints(cx, cy, r - 12)[0]], fill=INK + (60,), width=3)
        glyph(d, label, cx, cy - 28, 78)
        lf = F_LABEL if len(label) <= 8 else font(["DejaVuSans-Bold.ttf"], 22)
        tb = d.textbbox((0, 0), label, font=lf)
        d.text((cx - (tb[2] - tb[0]) / 2, cy + r * .48), label, font=lf, fill=WHITE,
               stroke_width=2, stroke_fill=(0, 0, 0, 120))
    return img


def centered(d, text, y, fnt, fill, stroke, sw=3):
    tb = d.textbbox((0, 0), text, font=fnt, stroke_width=sw)
    d.text(((W - (tb[2] - tb[0])) / 2, y), text, font=fnt, fill=fill,
           stroke_width=sw, stroke_fill=stroke)


def load_or(make, path):
    if os.path.exists(path):
        return Image.open(path).convert("RGBA").resize((W, H))
    im = make()
    im.convert("RGBA").save(path)
    return im.convert("RGBA")


def main():
    bg = load_or(make_background, os.path.join(HERE, "background.png"))
    fg = load_or(make_badges, os.path.join(HERE, "badges.png"))
    img = bg.copy()
    img.alpha_composite(fg)
    d = ImageDraw.Draw(img)

    centered(d, "RAGBAZ", 40, F_HERO, HERO_INK + (255,), (247, 243, 232, 220), sw=5)
    centered(d, "v-BAZ", H - 150, F_TAG, CINNABAR + (255,), (247, 243, 232, 220))
    centered(d, "containment-first virtualization host  ·  alpine · kvm · firecracker · kata",
             H - 92, F_SUB, HERO_INK + (255,), (247, 243, 232, 200), sw=3)

    out = img.convert("RGB")
    out.save(os.path.join(HERE, "vbaz-splash.png"))
    out.resize((1280, 720)).save(os.path.join(HERE, "splash-720.png"))
    print("wrote vbaz-splash.png (1920x1080) and splash-720.png")


if __name__ == "__main__":
    main()
