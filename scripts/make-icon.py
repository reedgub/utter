#!/usr/bin/env python3
"""Draws Resources/AppIcon.icns (and a PNG preview). Needs Pillow: pip install pillow."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

S = 1024
root = Path(__file__).resolve().parent.parent

def icon() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # macOS icon grid: 824 px tile centred on a 1024 canvas, ~185 px corner radius.
    tile, inset = 824, (S - 824) // 2
    radius = 185

    # Vertical gradient, deep blue to violet.
    top, bottom = (58, 76, 222), (132, 64, 214)
    grad = Image.new("RGBA", (tile, tile))
    gd = ImageDraw.Draw(grad)
    for y in range(tile):
        t = y / (tile - 1)
        gd.line([(0, y), (tile, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))

    mask = Image.new("L", (tile, tile), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, tile - 1, tile - 1], radius=radius, fill=255)

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + 14, inset + tile, inset + tile + 14], radius=radius, fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))
    img.paste(grad, (inset, inset), mask)

    # Waveform: five rounded bars.
    d = ImageDraw.Draw(img)
    heights = [0.26, 0.48, 0.70, 0.48, 0.26]
    bar_w, gap = 74, 46
    total = len(heights) * bar_w + (len(heights) - 1) * gap
    x = (S - total) // 2
    for h in heights:
        bh = int(tile * h)
        y0 = S // 2 - bh // 2
        d.rounded_rectangle([x, y0, x + bar_w, y0 + bh], radius=bar_w // 2, fill=(255, 255, 255, 245))
        x += bar_w + gap
    return img

if __name__ == "__main__":
    out = root / "Resources"
    img = icon()
    img.save(out / "AppIcon.png")
    img.save(out / "AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("wrote", out / "AppIcon.icns")
