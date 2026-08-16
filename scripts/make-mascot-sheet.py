# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Build merly-sprite.png (the app mascot mood sheet) from clawd-sprite.png.

clawd-sprite.png already carries all 8 mood rows x 4 anim frames — registered,
clean pixels, with the right per-mood eyes and Z/sweat/sparkle accessories. We
overlay the Merly wizard kit (purple hat + gold band, big brown handlebar
mustache, wooden staff with a gold orb) on every 128px frame, so the result is a
perfectly-registered, clean wizard sheet that reuses clawd's mood art.

Accessories are drawn smooth then block-pixelated (nearest) to match clawd's
~7px grid, and composited so the clawd pixels underneath stay pristine.

Row order (must match Mood.spriteRow): happy, content, tired, stressed,
sleeping, excited, wink, curious.
"""
from __future__ import annotations
import pathlib
from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources/Merly/Resources/clawd-sprite.png"
OUT = ROOT / "Sources/Merly/Resources/merly-sprite.png"

FW = 128
BLOCK = 7  # clawd's logical pixel size
PURPLE = (109, 60, 153, 255)
PURPLE_D = (78, 42, 112, 255)
GOLD = (227, 169, 49, 255)
BROWN = (92, 52, 30, 255)
BROWN_D = (58, 33, 18, 255)


def accessory_layer() -> Image.Image:
    """One 128x128 transparent overlay, identical on every frame."""
    a = Image.new("RGBA", (FW, FW), (0, 0, 0, 0))
    d = ImageDraw.Draw(a)
    # staff: pole + gold orb (right side)
    d.rectangle([106, 34, 113, 120], fill=BROWN)
    d.ellipse([100, 18, 122, 40], fill=GOLD)
    # hat: cone, brim, gold band
    d.polygon([(64, 10), (43, 42), (85, 42)], fill=PURPLE)
    d.rectangle([33, 42, 95, 49], fill=PURPLE)
    d.rectangle([33, 47, 95, 50], fill=PURPLE_D)
    d.rectangle([44, 35, 84, 42], fill=GOLD)
    # mustache: big handlebar over the mouth (eyes stay visible above it)
    d.rectangle([46, 80, 82, 87], fill=BROWN)
    d.polygon([(46, 80), (40, 82), (42, 92), (50, 88)], fill=BROWN)
    d.polygon([(82, 80), (88, 82), (86, 92), (78, 88)], fill=BROWN)
    d.rectangle([56, 87, 72, 92], fill=BROWN_D)
    # block-pixelate to clawd's grid
    lw = FW // BLOCK
    a = a.resize((lw, lw), Image.NEAREST).resize((lw * BLOCK, lw * BLOCK), Image.NEAREST)
    out = Image.new("RGBA", (FW, FW), (0, 0, 0, 0))
    out.alpha_composite(a)
    return out


def main() -> None:
    sheet = Image.open(SRC).convert("RGBA")
    cols, rows = 4, sheet.height // FW
    overlay = accessory_layer()
    out = sheet.copy()
    for r in range(rows):
        for c in range(cols):
            box = (c * FW, r * FW, c * FW + FW, r * FW + FW)
            frame = sheet.crop(box)
            frame.alpha_composite(overlay)
            out.paste(frame, box)
    out.save(OUT)
    print(f"wrote {OUT.relative_to(ROOT)} ({out.size[0]}x{out.size[1]}, {rows} moods x {cols} frames)")


if __name__ == "__main__":
    main()
