# -*- coding: utf-8 -*-
"""
PalmAcademic app icon, Apple-compliant:
  * flat solid background, full-bleed square 1024x1024, RGB, no alpha
  * the original brand mark in the centre: blue disc + white open book
  * a single liquid-glass touch: a soft rim of light around the disc
    (bright arc over the top edge, faint full ring) plus a subtle sheen
    across the pages -- the book itself is otherwise unchanged

Rendered at 2x (2048) and downscaled Lanczos. Same PNG is reused by the
in-app BrandLogo imageset.
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

SS = 2
S = 2048
OUT = 1024

BG = (232, 240, 255)        # #E8F0FF launcher background (the "original" solid)
DISC = (49, 93, 168)        # #315DA8 brand blue disc
PAGE_WHITE = (255, 255, 255)
PAGE_RIGHT = (229, 238, 252)  # #E5EEFC
SPINE = (157, 187, 235)       # #9DBBEB

K = S / 108.0                 # Android vector viewport scale


def p(x, y):
    return (x * K, y * K)


def cubic(p0, p1, p2, p3, steps=40):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        x = mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0]
        y = mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1]
        pts.append((x, y))
    return pts


def left_page():
    pts = [p(38.5, 42.5)]
    pts += cubic(p(38.5, 42.5), p(44.1, 40.9), p(49.1, 42.3), p(53, 46.1))
    pts += cubic(p(53, 46.1), p(51.5, 53), p(50.7, 60), p(53, 66.8))
    pts += cubic(p(53, 66.8), p(49.2, 63.4), p(44.5, 62.2), p(38.8, 63.8))
    pts += cubic(p(38.8, 63.8), p(37.4, 64.2), p(36, 63.2), p(36, 61.7))
    pts += [(p(36, 45.6)[0], p(36, 61.7)[1])]
    pts += cubic(p(36, 45.6), p(36, 44.2), p(37, 42.9), p(38.5, 42.5))
    return pts


def right_page():
    pts = [p(69.5, 42.5)]
    pts += cubic(p(69.5, 42.5), p(63.9, 40.9), p(58.9, 42.3), p(55, 46.1))
    pts += cubic(p(55, 46.1), p(56.5, 53), p(57.3, 60), p(55, 66.8))
    pts += cubic(p(55, 66.8), p(58.8, 63.4), p(63.5, 62.2), p(69.2, 63.8))
    pts += cubic(p(69.2, 63.8), p(70.6, 64.2), p(72, 63.2), p(72, 61.7))
    pts += [(p(72, 45.6)[0], p(72, 61.7)[1])]
    pts += cubic(p(72, 45.6), p(72, 44.2), p(71, 42.9), p(69.5, 42.5))
    return pts


def disc_box():
    cx = cy = 54 * K
    r = 25 * K
    return (cx - r, cy - r, cx + r, cy + r)


def ring_mask(size, box, width):
    """Annulus centred on the disc, `width` thick, on its outside edge."""
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    x0, y0, x1, y1 = box
    d.ellipse((x0 - width, y0 - width, x1 + width, y1 + width), fill=255)
    d.ellipse((x0 + width * 0.35, y0 + width * 0.35,
               x1 - width * 0.35, y1 - width * 0.35), fill=0)
    return m


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    icon_path = os.path.join(
        root, "iosApp", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png"
    )
    logo_dir = os.path.join(root, "iosApp", "Resources", "Assets.xcassets", "BrandLogo.imageset")
    os.makedirs(logo_dir, exist_ok=True)

    canvas = Image.new("RGBA", (S, S), BG + (255,))
    box = disc_box()
    cx = cy = 54 * K
    r = 25 * K

    # ---- disc with a very soft drop shadow so it lifts off the solid ground
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse(
        (box[0], box[1] + 14, box[2], box[3] + 26), fill=(20, 48, 110, 70)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    canvas.alpha_composite(shadow)

    d = ImageDraw.Draw(canvas)
    d.ellipse(box, fill=DISC + (255,))

    # ---- LIQUID-GLASS RIM around the disc -------------------------------
    # faint full ring
    ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.ellipse(box, outline=(255, 255, 255, 70), width=6)
    ring = ring.filter(ImageFilter.GaussianBlur(2))
    canvas.alpha_composite(ring)

    # bright glass arc sweeping over the TOP edge (screen coords: 200deg..340deg)
    rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rimd = ImageDraw.Draw(rim)
    arc_box = (box[0] - 4, box[1] - 4, box[2] + 4, box[3] + 4)
    rimd.arc(arc_box, start=202, end=338, fill=(255, 255, 255, 210), width=12)
    rim = rim.filter(ImageFilter.GaussianBlur(2.5))
    canvas.alpha_composite(rim)

    # second, tighter hot streak just inside the top edge
    hot = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(hot).arc(
        (box[0] + 10, box[1] + 10, box[2] - 10, box[3] - 10),
        start=214, end=326, fill=(255, 255, 255, 120), width=5
    )
    hot = hot.filter(ImageFilter.GaussianBlur(3))
    canvas.alpha_composite(hot)

    # a cool, faint refraction glow hugging the BOTTOM edge completes the ring
    cool = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(cool).arc(
        (box[0] + 2, box[1] + 2, box[2] - 2, box[3] - 2),
        start=28, end=152, fill=(190, 214, 250, 110), width=7
    )
    cool = cool.filter(ImageFilter.GaussianBlur(3.5))
    canvas.alpha_composite(cool)

    # ---- pages (unchanged shapes/colours) -------------------------------
    pages = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    pd = ImageDraw.Draw(pages)
    lp, rp = left_page(), right_page()
    pd.polygon(lp, fill=PAGE_WHITE + (255,))
    pd.polygon(rp, fill=PAGE_RIGHT + (255,))
    pd.line([p(53, 46.1), p(53, 66.8)], fill=SPINE + (255,), width=8)
    pd.line([p(55, 46.1), p(55, 66.8)], fill=(255, 255, 255, 150), width=5)
    canvas.alpha_composite(pages)

    # ---- glass sheen on the pages, clipped to their shapes ---------------
    sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh = ImageDraw.Draw(sheen)
    sh.polygon(
        [p(37.5, 44.5), p(52.5, 44.5), p(44, 57), p(37.5, 58.5)],
        fill=(255, 255, 255, 80),
    )
    sh.polygon(
        [p(55.5, 44.5), p(70.5, 44.5), p(70.5, 58.5), p(64, 57)],
        fill=(255, 255, 255, 80),
    )
    sheen = sheen.filter(ImageFilter.GaussianBlur(7))
    page_mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(page_mask)
    md.polygon(lp, fill=255)
    md.polygon(rp, fill=255)
    sheen.putalpha(
        Image.composite(sheen.getchannel("A"), Image.new("L", (S, S), 0), page_mask)
    )
    canvas.alpha_composite(sheen)

    final = canvas.convert("RGB").resize((OUT, OUT), Image.LANCZOS)
    final.save(icon_path, "PNG")
    logo_path = os.path.join(logo_dir, "brand-logo.png")
    final.save(logo_path, "PNG")
    print("wrote", icon_path)
    print("wrote", logo_path)


if __name__ == "__main__":
    main()
