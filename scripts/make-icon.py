#!/usr/bin/env python3
"""Renders Resources/AppIcon.icns and design/logo/icon/*.png from the D2 mascot master.

Usage: python3 scripts/make-icon.py   (needs Pillow: pip install pillow)

The master is a full-bleed 1024px square. The .icns follows the macOS icon grid: the body is
824px of the 1024 canvas with a continuous-ish rounded corner and a soft drop shadow, so it sits
next to other Mac apps. design/logo/icon/ also gets plain rounded and square cuts for other uses.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / "design/logo/source/D2-original.png"
LOGO = ROOT / "design/logo"
SIZES = (1024, 512, 256, 180, 128, 64, 32, 16)
SS = 4  # supersampling for anti-aliased masks


def rounded_mask(size: int, radius: float) -> Image.Image:
    big = Image.new("L", (size * SS, size * SS), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, size * SS - 1, size * SS - 1), radius=radius * SS, fill=255)
    return big.resize((size, size), Image.LANCZOS)


def mac_icon(master: Image.Image, canvas: int = 1024) -> Image.Image:
    body = round(canvas * 0.805)  # 824 / 1024
    off = (canvas - body) // 2
    art = master.resize((body, body), Image.LANCZOS)
    art.putalpha(rounded_mask(body, body * 0.225))

    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 72), (off, off + round(canvas * 0.012)), art.getchannel("A"))
    out.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(canvas * 0.02)))
    out.alpha_composite(art, (off, off))
    return out


def main() -> None:
    master = Image.open(MASTER).convert("RGBA")
    assert master.size[0] == master.size[1], "master must be square"

    icon = mac_icon(master)
    icon.save(ROOT / "Resources/AppIcon.icns", sizes=[(s, s) for s in (16, 32, 64, 128, 256, 512, 1024)])

    for shape in ("macos", "rounded", "square"):
        d = LOGO / "icon" / shape
        d.mkdir(parents=True, exist_ok=True)
        for s in SIZES:
            if shape == "macos":
                img = icon.resize((s, s), Image.LANCZOS)
            else:
                img = master.resize((s, s), Image.LANCZOS)
                if shape == "rounded":
                    img.putalpha(rounded_mask(s, s * 0.2237))
            img.save(d / f"ntfy-{shape}-{s}.png", optimize=True)
    print("wrote Resources/AppIcon.icns and design/logo/icon/{macos,rounded,square}")


if __name__ == "__main__":
    main()
