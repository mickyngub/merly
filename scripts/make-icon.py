# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Build Merlyn.icns from the Merlyn wizard mascot sprite.

`merlyn-mascot.png` is the crisp, pre-pixelated wizard-Clawd sprite (our canonical
Clawd frame with a wizard hat, big handlebar mustache, and a gold-orb staff),
stored transparent. We drop it, scaled to fill, on a full-bleed dark charcoal
squircle that matches the Merlyn panel, then emit the full .iconset and run
iconutil.

To restyle the mascot: replace merlyn-mascot.png (a transparent pixel sprite) and
re-run. The raw source art + de-smudge pipeline live in sprite-work/perch/
(gitignored dev scratch); this script only needs the baked sprite.
"""
from __future__ import annotations
import pathlib
import subprocess
from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPRITE = ROOT / "scripts/merlyn-mascot.png"
ICONSET = ROOT / "scripts/Merlyn.iconset"
ICNS = ROOT / "scripts/Merlyn.icns"

SIZE = 1024
NAVY = (31, 35, 41, 255)     # Merlyn panel charcoal
RADIUS = 0.2237              # squircle corner radius (macOS icon grid)
FILL = 0.82                  # sprite's longest side as a fraction of the canvas

ICON_SIZES = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]


def master() -> Image.Image:
    sprite = Image.open(SPRITE).convert("RGBA")
    sprite = sprite.crop(sprite.getbbox())
    scale = (FILL * SIZE) / max(sprite.size)
    sprite = sprite.resize(
        (round(sprite.width * scale), round(sprite.height * scale)), Image.NEAREST
    )
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(canvas).rounded_rectangle(
        [0, 0, SIZE - 1, SIZE - 1], radius=round(RADIUS * SIZE), fill=NAVY
    )
    canvas.alpha_composite(
        sprite, ((SIZE - sprite.width) // 2, (SIZE - sprite.height) // 2)
    )
    return canvas


def main() -> None:
    icon = master()
    ICONSET.mkdir(parents=True, exist_ok=True)
    for size, name in ICON_SIZES:
        icon.resize((size, size), Image.LANCZOS).save(ICONSET / name)
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    print(f"Wrote {ICNS.relative_to(ROOT)} ({ICNS.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
