#!/usr/bin/env python3
"""Generates the app icon and launch images for iOS 6 (run in CI, needs Pillow).

The icon: Twitch's "Glitch" (the speech bubble with two eyes, black body with a white face, as on twitch.tv) on a
purple gradient tile with a soft shadow under it, the way icons looked in 2012. iOS 6 adds its own shine on top
(UIPrerenderedIcon is false).

Usage: python3 tools/gen_assets.py Resources
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = sys.argv[1] if len(sys.argv) > 1 else "Resources"
APP_NAME = "Twitcher"
os.makedirs(OUT, exist_ok=True)

FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
    "/Library/Fonts/Arial Bold.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
]

_R = getattr(Image, "Resampling", Image)
LANCZOS, NEAREST = _R.LANCZOS, _R.NEAREST


def font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    try:
        return ImageFont.load_default(size)  # Pillow >= 10.1
    except TypeError:
        sys.exit("gen_assets: no TrueType font found (install fonts-dejavu-core)")


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vertical_gradient(size, top, bottom):
    w, h = size
    col = Image.new("RGB", (1, h))
    col.putdata([lerp(top, bottom, y / max(1, h - 1)) for y in range(h)])
    return col.resize((w, h), NEAREST)


def text_size(draw, text, fnt):
    if hasattr(draw, "textbbox"):
        l, t, r, b = draw.textbbox((0, 0), text, font=fnt)
        return r - l, b - t, l, t
    w, h = draw.textsize(text, font=fnt)
    return w, h, 0, 0


_BASE_ICON = None


# The Glitch, in the 2400 x 2800 grid of Twitch's own drawing: the body (black, with the top-left corner cut and the
# tail at the bottom), the face (white) and the two eyes
GLITCH_BODY = [(500, 0), (0, 500), (0, 2300), (600, 2300), (600, 2800), (1100, 2300), (1500, 2300), (2400, 1400), (2400, 0)]
GLITCH_FACE = [(600, 200), (2200, 200), (2200, 1300), (1800, 1700), (1400, 1700), (1050, 2050), (1050, 1700), (600, 1700)]
GLITCH_EYES = [(1150, 550, 1350, 1150), (1700, 550, 1900, 1150)]
GLITCH_DARK = (16, 10, 28, 255)


def base_icon():
    """The 1024 px master icon, drawn once."""
    global _BASE_ICON
    if _BASE_ICON is not None:
        return _BASE_ICON
    base = 1024
    img = vertical_gradient((base, base), (166, 120, 255), (108, 58, 220)).convert("RGBA")
    # a soft light from above, fading out by the middle (iOS 6 adds its own shine as well)
    light = Image.new("L", (1, base))
    light.putdata([int(60 * max(0.0, 1 - y / (base * 0.55))) for y in range(base)])
    highlight = Image.new("RGBA", (base, base), (255, 255, 255, 0))
    highlight.putalpha(light.resize((base, base), NEAREST))
    img = Image.alpha_composite(img, highlight)

    # the glyph takes 60 % of the height, a little above the middle (the tail hangs below the body)
    scale = base * 0.60 / 2800
    x0, y0 = (base - 2400 * scale) / 2, (base - 2800 * scale) / 2 - base * 0.02

    def pts(points, dy=0):
        return [(x0 + x * scale, y0 + (y + dy) * scale) for x, y in points]

    # a soft shadow under the body gives the tile the depth icons had then
    shadow = Image.new("RGBA", (base, base), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon(pts(GLITCH_BODY, dy=70), fill=(40, 10, 90, 150))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(14)))

    d = ImageDraw.Draw(img)
    d.polygon(pts(GLITCH_BODY), fill=GLITCH_DARK)
    d.polygon(pts(GLITCH_FACE), fill=(255, 255, 255, 255))
    for ex0, ey0, ex1, ey1 in GLITCH_EYES:
        d.rectangle((x0 + ex0 * scale, y0 + ey0 * scale, x0 + ex1 * scale, y0 + ey1 * scale), fill=GLITCH_DARK)
    _BASE_ICON = img.convert("RGB")
    return _BASE_ICON


def make_icon(size):
    return base_icon().resize((size, size), LANCZOS)


def make_launch(w, h):
    img = vertical_gradient((w, h), (236, 238, 243), (214, 217, 226))
    d = ImageDraw.Draw(img)
    s = int(min(w, h) * 0.18)
    icon = make_icon(s)
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, s - 1, s - 1), radius=int(s * 0.22), fill=255)
    cx, cy = w // 2, int(h * 0.42)
    img.paste(icon, (cx - s // 2, cy - s // 2), mask)
    fnt = font(int(min(w, h) * 0.06))
    tw, th, l, t = text_size(d, APP_NAME, fnt)
    d.text((cx - tw // 2 - l, cy + s // 2 + int(s * 0.25) - t), APP_NAME, font=fnt, fill=(70, 74, 86))
    return img


ICONS = {
    "Icon.png": 57,
    "Icon@2x.png": 114,
    "Icon-72.png": 72,
    "Icon-72@2x.png": 144,
    "Icon-Small.png": 29,
    "Icon-Small@2x.png": 58,
    "Icon-Small-50.png": 50,
    "Icon-Small-50@2x.png": 100,
}

LAUNCH = {
    "Default.png": (320, 480),
    "Default@2x.png": (640, 960),
    "Default-568h@2x.png": (640, 1136),
    "Default-Portrait~ipad.png": (768, 1004),
    "Default-Portrait@2x~ipad.png": (1536, 2008),
    "Default-Landscape~ipad.png": (1024, 748),
    "Default-Landscape@2x~ipad.png": (2048, 1496),
}

for name, size in ICONS.items():
    make_icon(size).save(os.path.join(OUT, name), "PNG")
    print("icon", name)

for name, (w, h) in LAUNCH.items():
    make_launch(w, h).save(os.path.join(OUT, name), "PNG")
    print("launch", name)
