# -*- coding: utf-8 -*-
"""
Generates the PalmAcademic app icon: a liquid-glass open book on a brand-blue
gradient, full-bleed square at 1024x1024 (Apple App Icon requirement: RGB, no
alpha, no rounded corners, no transparency).

Rendered at 2x (2048) and downscaled with Lanczos so glass blur, rim light and
the curved page edges stay smooth. The same flattened PNG is reused by the
in-app BrandLogo imageset and the small Android login mark.
"""
import math
import os

from PIL import Image, ImageDraw, ImageFilter

SS = 2  # supersample factor
S = 2048
OUT = 1024


def cubic(p0, p1, p2, p3, steps=48):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        x = mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0]
        y = mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1]
        pts.append((x, y))
    return pts


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGB", (1, h))
    px = grad.load()
    for y in range(h):
        px[0, y] = lerp(top, bottom, y / max(h - 1, 1))
    return grad.resize((w, h))


def page_path(side):
    """Open-book page outline. side: 'left' or 'right'."""
    if side == "left":
        inner_top = (1006, 700)
        outer_top_c1 = (780, 596)
        outer_top_c2 = (600, 612)
        outer_top = (560, 660)
        outer_bottom = (560, 1300)
        outer_bot_c2 = (600, 1344)
        outer_bot_c1 = (780, 1368)
        inner_bottom = (1006, 1372)
    else:
        inner_top = (1042, 700)
        outer_top_c1 = (1268, 596)
        outer_top_c2 = (1448, 612)
        outer_top = (1488, 660)
        outer_bottom = (1488, 1300)
        outer_bot_c2 = (1448, 1344)
        outer_bot_c1 = (1268, 1368)
        inner_bottom = (1042, 1372)

    pts = [inner_top]
    pts += cubic(inner_top, outer_top_c1, outer_top_c2, outer_top, 44)[1:]
    pts += cubic(outer_top, (outer_top[0] - 12, 880), (outer_bottom[0] - 12, 1080), outer_bottom, 44)[1:]
    pts += cubic(outer_bottom, outer_bot_c2, outer_bot_c1, inner_bottom, 44)[1:]
    pts.append(inner_bottom if side == "left" else inner_top)
    return pts


def mask_of(polygon):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).polygon(polygon, fill=255)
    return m


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    icon_path = os.path.join(
        root, "iosApp", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon-1024.png"
    )
    logo_dir = os.path.join(root, "iosApp", "Resources", "Assets.xcassets", "BrandLogo.imageset")
    os.makedirs(logo_dir, exist_ok=True)

    # ---------------------------------------------------------------- background
    canvas = vertical_gradient((S, S), (111, 158, 246), (29, 61, 132)).convert("RGBA")

    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    # soft key light, top centre
    gd.ellipse((520, -520, 1528, 520), fill=(255, 255, 255, 46))
    # chromatic refraction wash around where the glass sits
    gd.ellipse((300, 760, 1180, 1720), fill=(120, 226, 255, 40))
    gd.ellipse((880, 700, 1780, 1680), fill=(168, 150, 255, 34))
    glow = glow.filter(ImageFilter.GaussianBlur(150))
    canvas.alpha_composite(glow)

    # Optically centre the book: the drop shadow below it adds visual weight, so shift the
    # glyph slightly under the geometric middle to read centred.
    BOOK_Y = 48

    def centred(poly):
        return [(x, y + BOOK_Y) for x, y in poly]

    left = centred(page_path("left"))
    right = centred(page_path("right"))

    # ------------------------------------------------------------------ shadow
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.polygon(left, fill=(8, 22, 58, 150))
    sd.polygon(right, fill=(8, 22, 58, 150))
    shadow = shadow.filter(ImageFilter.GaussianBlur(52))
    shifted = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shifted.alpha_composite(shadow, (0, 46))
    canvas.alpha_composite(shifted)

    # glass fill: frosted white-blue, brighter toward the top of each page
    fill = vertical_gradient((S, S), (247, 251, 255), (202, 224, 255)).convert("RGBA")
    fill.putalpha(0)
    fpx = fill.load()

    def paint_pages(base_layer):
        for poly in (left, right):
            mask = mask_of(poly).filter(ImageFilter.GaussianBlur(2))
            page = Image.new("RGBA", (S, S), (0, 0, 0, 0))
            grad = vertical_gradient((S, S), (252, 254, 255), (205, 227, 255)).convert("RGBA")
            grad.putalpha(mask)
            page.alpha_composite(grad)
            # bottom refraction tint (cool blue gathering at the lower edge)
            cool = Image.new("RGBA", (S, S), (0, 0, 0, 0))
            cd = ImageDraw.Draw(cool)
            cd.polygon(poly, fill=(63, 110, 205, 0))
            band = Image.new("RGBA", (S, S), (40, 86, 178, 70))
            band.putalpha(
                Image.composite(
                    Image.new("L", (S, S), 70), Image.new("L", (S, S), 0),
                    mask.filter(ImageFilter.GaussianBlur(2))
                )
            )
            band = band.crop((0, int(S * 0.62), S, S))
            band_mask = Image.new("L", (S, S), 0)
            ImageDraw.Draw(band_mask).polygon(poly, fill=255)
            band_full = Image.new("RGBA", (S, S), (0, 0, 0, 0))
            band_full.paste(band, (0, int(S * 0.62)))
            band_full.putalpha(
                Image.composite(
                    band_full.getchannel("A"), Image.new("L", (S, S), 0),
                    band_mask.filter(ImageFilter.GaussianBlur(2))
                )
            )
            page.alpha_composite(band_full)
            base_layer.alpha_composite(page)

    glass = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    paint_pages(glass)

    # rim light: bright top edges, cool dark bottom edges
    rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    for poly in (left, right):
        top_arc = poly[:46]
        outer = poly[45:91]
        bottom_arc = poly[90:136]
        rd.line(top_arc, fill=(255, 255, 255, 235), width=12, joint="curve")
        rd.line(outer, fill=(255, 255, 255, 90), width=8, joint="curve")
        rd.line(bottom_arc, fill=(30, 66, 140, 120), width=9, joint="curve")
        # spine-side sheen
        spine_edge = [poly[-1], poly[0]]
        rd.line(spine_edge, fill=(255, 255, 255, 150), width=6)
    rim = rim.filter(ImageFilter.GaussianBlur(1.2))
    glass.alpha_composite(rim)

    # diagonal specular streak across each page
    sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh = ImageDraw.Draw(sheen)
    sh.polygon([(560, 700), (992, 690), (760, 1010), (470, 1040)], fill=(255, 255, 255, 96))
    sh.polygon([(1056, 690), (1488, 700), (1578, 1040), (1288, 1010)], fill=(255, 255, 255, 96))
    sheen = sheen.filter(ImageFilter.GaussianBlur(14))
    sheen_mask = Image.new("L", (S, S), 0)
    sm = ImageDraw.Draw(sheen_mask)
    sm.polygon(left, fill=255)
    sm.polygon(right, fill=255)
    sheen.putalpha(Image.composite(sheen.getchannel("A"), Image.new("L", (S, S), 0), sheen_mask))
    glass.alpha_composite(sheen)

    # spine: glass fold highlight + two soft fold shadows
    spine = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sp = ImageDraw.Draw(spine)
    sp.rounded_rectangle((1004, 712, 1044, 1360), radius=20, fill=(255, 255, 255, 120))
    sp.line([(1002, 712), (1002, 1358)], fill=(18, 46, 110, 90), width=8)
    sp.line([(1046, 712), (1046, 1358)], fill=(18, 46, 110, 90), width=8)
    spine = spine.filter(ImageFilter.GaussianBlur(3))
    glass.alpha_composite(spine)

    # page-content whispers: a few faint rounded lines so the glass reads as paper
    lines = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(lines)
    for side_cx, inward in ((770, 1), (1278, -1)):
        for i, y in enumerate((842, 936, 1030)):
            length = 300 - i * 26
            x0 = side_cx - length // 2 if inward == 1 else side_cx - length // 2
            ld.rounded_rectangle(
                (side_cx - length // 2, y, side_cx + length // 2 - 40 * (i + 1) * inward, y + 14),
                radius=7, fill=(70, 110, 190, 42)
            )
    lines = lines.filter(ImageFilter.GaussianBlur(2))
    line_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(line_mask).polygon(left, fill=255)
    ImageDraw.Draw(line_mask).polygon(right, fill=255)
    lines.putalpha(Image.composite(lines.getchannel("A"), Image.new("L", (S, S), 0), line_mask))
    glass.alpha_composite(lines)

    canvas.alpha_composite(glass)

    # big soft top sheen over the whole mark (liquid-glass ceiling reflection)
    top = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    td = ImageDraw.Draw(top)
    td.ellipse((300, 360, 1748, 1180), fill=(255, 255, 255, 26))
    top = top.filter(ImageFilter.GaussianBlur(120))
    canvas.alpha_composite(top)

    # Apple requires an RGB icon with no alpha.
    final = canvas.convert("RGB").resize((OUT, OUT), Image.LANCZOS)
    final.save(icon_path, "PNG")
    logo_path = os.path.join(logo_dir, "brand-logo.png")
    final.save(logo_path, "PNG")
    print("wrote", icon_path)
    print("wrote", logo_path)


if __name__ == "__main__":
    main()
