"""Composes docs/hero.png for the README: panel screenshots side by side on the
brand gradient, equal width, top-aligned, with soft shadows.

Usage: python3 design/tools/make-readme-hero.py   (needs Pillow)
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SHOTS = ROOT / "docs" / "screenshots"
PANELS = ["panel-builtin.png", "panel-virtual.png", "panel-arrangement.png"]

GAP, PAD_X, PAD_TOP, PAD_BOTTOM = 72, 120, 110, 120
RADIUS = 56


def gradient(size):
    """Diagonal indigo → blue, like the app icon, darkened so the panels stand out."""
    w, h = size
    start, end = (58, 40, 140), (12, 70, 150)
    base = Image.new("RGB", size)
    draw = ImageDraw.Draw(base)
    for x in range(w):
        t = x / max(w - 1, 1)
        draw.line([(x, 0), (x, h)], fill=tuple(int(a + (b - a) * t) for a, b in zip(start, end)))
    # Soft light from the top left, dark vignette at the bottom.
    glow = Image.new("L", size, 0)
    ImageDraw.Draw(glow).ellipse([-w * 0.3, -h * 0.9, w * 0.7, h * 0.6], fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(w // 8))
    base = Image.composite(Image.new("RGB", size, (150, 130, 255)), base, glow)
    return base.convert("RGBA")


def main():
    panels = [Image.open(SHOTS / name).convert("RGBA") for name in PANELS]
    width = max(p.width for p in panels)
    panels = [p if p.width == width else p.resize((width, int(p.height * width / p.width))) for p in panels]
    height = max(p.height for p in panels)

    canvas_size = (PAD_X * 2 + width * len(panels) + GAP * (len(panels) - 1), PAD_TOP + height + PAD_BOTTOM)
    canvas = gradient(canvas_size)

    for index, panel in enumerate(panels):
        x = PAD_X + index * (width + GAP)
        shadow = Image.new("RGBA", canvas_size, (0, 0, 0, 0))
        mask = panel.split()[3].point(lambda a: 150 if a > 0 else 0)
        shadow.paste((0, 0, 0, 255), (x, PAD_TOP + 36), mask)
        canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(40)))
        canvas.alpha_composite(panel, (x, PAD_TOP))

    # Round the outer corners so the image sits nicely on GitHub's page.
    corners = Image.new("L", canvas_size, 0)
    ImageDraw.Draw(corners).rounded_rectangle([0, 0, canvas_size[0] - 1, canvas_size[1] - 1], RADIUS, fill=255)
    canvas.putalpha(corners)

    out = ROOT / "docs" / "hero.png"
    canvas.save(out, optimize=True)
    print(f"wrote {out} {canvas.size}")


if __name__ == "__main__":
    main()
