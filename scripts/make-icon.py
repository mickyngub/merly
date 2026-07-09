# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Build Lens.icns from the happy Clawd sprite frame.

Composites the top-left (mood row 0, idle frame 0) cell of clawd-sprite.png —
the canonical smiling Clawd — centered on a dark charcoal squircle that matches
the Usage Dock panel, then emits a full .iconset and runs iconutil.

Rendered fresh at every icon size (nearest-neighbour on the pixel-art critter)
so the pixels stay crisp from 16px to 1024px instead of blurring under a single
downscale.
"""
from __future__ import annotations
import pathlib
import subprocess
from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPRITE = ROOT / "Sources/Lens/Resources/clawd-sprite.png"
ICONSET = ROOT / "scripts/Lens.iconset"
ICNS = ROOT / "scripts/Lens.icns"

FRAME = 128          # clawd-sprite.png is a 4-col x 8-row grid of 128px cells
BG_TOP = (44, 44, 52)      # charcoal gradient — lighter top
BG_BOTTOM = (22, 22, 28)   # ...darker bottom, for a bit of depth
MARGIN = 0.085       # transparent border around the squircle (Apple icon grid)
RADIUS = 0.2237      # squircle corner radius as a fraction of the content box
CRITTER_FILL = 0.60  # critter's longest side as a fraction of the canvas


def clawd_frame() -> Image.Image:
    """Row 0, col 0 of the sheet, cropped tight to the critter's pixels."""
    sheet = Image.open(SPRITE).convert("RGBA")
    cell = sheet.crop((0, 0, FRAME, FRAME))
    bbox = cell.getbbox()  # trim transparent margins so scaling is by real pixels
    return cell.crop(bbox) if bbox else cell


def gradient_bg(size: int) -> Image.Image:
    """Vertical charcoal gradient the size of the canvas."""
    grad = Image.new("RGBA", (size, size))
    px = grad.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        r = round(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        g = round(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        b = round(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        for x in range(size):
            px[x, y] = (r, g, b, 255)
    return grad


def compose(size: int, critter: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    inset = round(size * MARGIN)
    box = size - 2 * inset
    radius = round(box * RADIUS)

    # Rounded-rect (squircle-ish) mask for the charcoal background.
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset, inset, size - inset - 1, size - inset - 1), radius=radius, fill=255
    )
    canvas.paste(gradient_bg(size), (0, 0), mask)

    # Scale the critter by its longest side, keeping pixels sharp.
    target = size * CRITTER_FILL
    scale = target / max(critter.width, critter.height)
    cw, ch = round(critter.width * scale), round(critter.height * scale)
    scaled = critter.resize((cw, ch), Image.NEAREST)

    # Centered, nudged up ~2% so the legs don't crowd the bottom edge.
    x = (size - cw) // 2
    y = (size - ch) // 2 - round(size * 0.02)
    canvas.paste(scaled, (x, y), scaled)
    return canvas


def main() -> None:
    critter = clawd_frame()
    ICONSET.mkdir(parents=True, exist_ok=True)

    # (pixel size, iconset filename) — the standard 10 macOS slots.
    slots = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    rendered: dict[int, Image.Image] = {}
    for px, name in slots:
        if px not in rendered:
            rendered[px] = compose(px, critter)
        rendered[px].save(ICONSET / name)

    subprocess.run(
        ["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True
    )
    print(f"Wrote {ICNS.relative_to(ROOT)} ({ICNS.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
