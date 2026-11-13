"""Draws the SpotVault logo and exports every icon size the apps need.

    python assets/make_icon.py

Writes:
    assets/logo_1024.png             master image
    assets/app_icon.ico              Windows exe / installer icon (16-256 px)
    app_icon.ico, web/app_icon.ico   copies used by the build and landing page
    spotvault_mobile/android/app/src/main/res/mipmap-*/ic_launcher.png
"""
import math
import os
import shutil

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024          # final size
SS = 4            # supersampling factor for smooth edges
N = S * SS

ACCENT = (139, 92, 246)       # violet
ACCENT_DARK = (79, 70, 229)   # indigo
BG_TOP = (30, 28, 58)
BG_BOTTOM = (11, 11, 20)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        d.line([(0, y), (size, y)], fill=lerp(top, bottom, y / size))
    return img


def draw_logo():
    # Rounded-square dark tile
    tile = vertical_gradient(N, BG_TOP, BG_BOTTOM).convert("RGBA")
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, N - 1, N - 1), radius=int(N * 0.225), fill=255)
    tile.putalpha(mask)

    cx = cy = N / 2
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    # Vault door: violet-to-indigo gradient disc
    r_outer = N * 0.36
    disc = vertical_gradient(N, ACCENT, ACCENT_DARK).convert("RGBA")
    dmask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(dmask).ellipse((cx - r_outer, cy - r_outer, cx + r_outer, cy + r_outer), fill=255)
    disc.putalpha(dmask)

    # Soft glow under the disc
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((cx - r_outer, cy - r_outer + N * 0.02, cx + r_outer, cy + r_outer + N * 0.02),
                                 fill=(139, 92, 246, 110))
    glow = glow.filter(ImageFilter.GaussianBlur(N * 0.04))

    # Dial ticks around the door (like a safe dial)
    for i in range(24):
        a = 2 * math.pi * i / 24
        long = i % 6 == 0
        r1 = r_outer * (0.80 if long else 0.85)
        r2 = r_outer * 0.93
        w = int(N * (0.014 if long else 0.008))
        d.line([(cx + r1 * math.cos(a), cy + r1 * math.sin(a)),
                (cx + r2 * math.cos(a), cy + r2 * math.sin(a))], fill=(0, 0, 0, 90), width=w)

    # Inner black ring
    r_in = r_outer * 0.72
    d.ellipse((cx - r_in, cy - r_in, cx + r_in, cy + r_in), fill=(11, 11, 20, 255))

    # Music note (beamed eighth notes) in white
    white = (255, 255, 255, 255)
    head_r = N * 0.052
    x1, x2 = cx - N * 0.095, cx + N * 0.085
    y1, y2 = cy + N * 0.085, cy + N * 0.055
    stem_w = N * 0.026
    top1, top2 = cy - N * 0.115, cy - N * 0.145
    for hx, hy in ((x1, y1), (x2, y2)):
        d.ellipse((hx - head_r * 1.15, hy - head_r * 0.85, hx + head_r * 1.15, hy + head_r * 0.85), fill=white)
    s1 = x1 + head_r * 1.15 - stem_w
    s2 = x2 + head_r * 1.15 - stem_w
    d.rectangle((s1, top1, s1 + stem_w, y1), fill=white)
    d.rectangle((s2, top2, s2 + stem_w, y2), fill=white)
    beam = N * 0.05
    d.polygon([(s1, top1), (s2 + stem_w, top2), (s2 + stem_w, top2 + beam), (s1, top1 + beam)], fill=white)

    # Lock handle notch at the bottom of the ring
    d.rounded_rectangle((cx - N * 0.03, cy + r_in - N * 0.01, cx + N * 0.03, cy + r_outer * 0.97),
                        radius=int(N * 0.012), fill=(11, 11, 20, 255))

    out = Image.alpha_composite(tile, glow)
    out = Image.alpha_composite(out, disc)
    out = Image.alpha_composite(out, layer)
    # Keep the rounded-square silhouette after compositing
    out.putalpha(Image.composite(out.getchannel("A"), Image.new("L", (N, N), 0), mask))
    return out.resize((S, S), Image.Resampling.LANCZOS)


def main():
    logo = draw_logo()
    assets = os.path.join(ROOT, "assets")
    logo.save(os.path.join(assets, "logo_1024.png"))

    ico = os.path.join(assets, "app_icon.ico")
    logo.save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    for copy in (os.path.join(ROOT, "app_icon.ico"), os.path.join(ROOT, "web", "app_icon.ico")):
        if os.path.isdir(os.path.dirname(copy)):
            shutil.copyfile(ico, copy)

    res = os.path.join(ROOT, "spotvault_mobile", "android", "app", "src", "main", "res")
    for folder, px in {"mipmap-mdpi": 48, "mipmap-hdpi": 72, "mipmap-xhdpi": 96,
                       "mipmap-xxhdpi": 144, "mipmap-xxxhdpi": 192}.items():
        path = os.path.join(res, folder)
        os.makedirs(path, exist_ok=True)
        logo.resize((px, px), Image.Resampling.LANCZOS).save(os.path.join(path, "ic_launcher.png"))
    # iOS: Apple rounds the corners itself and rejects transparency, so fill the
    # tile edge-to-edge (draw on the dark background, no rounded mask).
    appicon = os.path.join(ROOT, "spotvault_mobile", "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    if os.path.isdir(appicon):
        flat = Image.new("RGB", logo.size, BG_BOTTOM)
        # Re-draw without the rounded-square cut: scale the artwork up slightly
        inner = logo.resize((int(S * 1.12), int(S * 1.12)), Image.Resampling.LANCZOS)
        off = (S - inner.width) // 2
        flat.paste(inner, (off, off), inner)
        for name in os.listdir(appicon):
            if name.endswith(".png"):
                path = os.path.join(appicon, name)
                with Image.open(path) as old:
                    size = old.size
                flat.resize(size, Image.Resampling.LANCZOS).save(path)

    print("icons written")


if __name__ == "__main__":
    main()
