"""Builds Resources/Doppio.icon, an Icon Composer package (macOS 26 Liquid Glass icon).

Same geometry as make-doppio-icon.py, split into layers so the system renders
each one as glass: the real display (bezel, screen, stand) in front of its dashed twin.
Usage: python3 design/tools/make-doppio-iconpackage.py
"""
import json
import math
from pathlib import Path



ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "Resources" / "Doppio.icon"

# Geometry (1024 grid), mirrors make-doppio-icon.py.
W, H, R = 440, 300, 44
D = 120
BEZEL = 20
STAND_W, STAND_H, STAND_GAP = 96, 20, 22
group_w, group_h = W + D, H + D + STAND_GAP + STAND_H
x0, y0 = 512 - group_w / 2, 512 - group_h / 2 + 4
back, front = (x0, y0), (x0 + D, y0 + D)
DASHES, DASH_FILL = 20, 0.62
# Icon Composer's SVG renderer ignores pathLength, so dash lengths are absolute.
PERIMETER = 2 * (W - 2 * R) + 2 * (H - 2 * R) + 2 * math.pi * R
PERIOD = PERIMETER / DASHES


def rounded_rect_from_top_center(x, y, w, h, r):
    k = 0.5523 * r
    return (
        f"M{x + w / 2:.2f},{y:.2f} H{x + w - r:.2f} "
        f"C{x + w - r + k:.2f},{y:.2f} {x + w:.2f},{y + r - k:.2f} {x + w:.2f},{y + r:.2f} V{y + h - r:.2f} "
        f"C{x + w:.2f},{y + h - r + k:.2f} {x + w - r + k:.2f},{y + h:.2f} {x + w - r:.2f},{y + h:.2f} H{x + r:.2f} "
        f"C{x + r - k:.2f},{y + h:.2f} {x:.2f},{y + h - r + k:.2f} {x:.2f},{y + h - r:.2f} V{y + r:.2f} "
        f"C{x:.2f},{y + r - k:.2f} {x + r - k:.2f},{y:.2f} {x + r:.2f},{y:.2f} Z"
    )


def svg(body, defs=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            f'<defs>{defs}</defs>{body}</svg>')


bx, by = back
fx, fy = front
inner = (fx + BEZEL, fy + BEZEL, W - 2 * BEZEL, H - 2 * BEZEL)
inner_r = R - BEZEL + 4

layers = {
    # Dashed virtual twin with a faint frosted fill.
    "twin.svg": svg(
        f'<path d="{rounded_rect_from_top_center(bx, by, W, H, R)}" fill="#FFFFFF" fill-opacity="0.22"/>'
        f'<path d="{rounded_rect_from_top_center(bx, by, W, H, R)}" fill="none" stroke="#FFFFFF" stroke-width="16" '
        f'stroke-dasharray="{PERIOD * DASH_FILL:.2f} {PERIOD * (1 - DASH_FILL):.2f}" stroke-dashoffset="{PERIOD * DASH_FILL / 2:.2f}" stroke-linecap="round"/>'
    ),
    # White bezel with the screen cut out (even-odd), so the screen layer shows through.
    "bezel.svg": svg(
        f'<path fill-rule="evenodd" fill="#FFFFFF" d="'
        f'M{fx + R},{fy} H{fx + W - R} A{R},{R} 0 0 1 {fx + W},{fy + R} V{fy + H - R} A{R},{R} 0 0 1 {fx + W - R},{fy + H} '
        f'H{fx + R} A{R},{R} 0 0 1 {fx},{fy + H - R} V{fy + R} A{R},{R} 0 0 1 {fx + R},{fy} Z '
        f'M{inner[0] + inner_r},{inner[1]} H{inner[0] + inner[2] - inner_r} A{inner_r},{inner_r} 0 0 1 {inner[0] + inner[2]},{inner[1] + inner_r} '
        f'V{inner[1] + inner[3] - inner_r} A{inner_r},{inner_r} 0 0 1 {inner[0] + inner[2] - inner_r},{inner[1] + inner[3]} '
        f'H{inner[0] + inner_r} A{inner_r},{inner_r} 0 0 1 {inner[0]},{inner[1] + inner[3] - inner_r} '
        f'V{inner[1] + inner_r} A{inner_r},{inner_r} 0 0 1 {inner[0] + inner_r},{inner[1]} Z"/>'
    ),
    # Wallpaper on the screen, with a menu bar strip.
    "screen.svg": svg(
        f'<rect x="{inner[0]}" y="{inner[1]}" width="{inner[2]}" height="{inner[3]}" rx="{inner_r}" fill="url(#wall)"/>'
        f'<rect x="{inner[0]}" y="{inner[1]}" width="{inner[2]}" height="18" fill="#FFFFFF" fill-opacity="0.5" clip-path="url(#clip)"/>',
        '<linearGradient id="wall" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0" stop-color="#2F45FF"/><stop offset="0.55" stop-color="#6A4DFF"/><stop offset="1" stop-color="#F06BB4"/></linearGradient>'
        f'<clipPath id="clip"><rect x="{inner[0]}" y="{inner[1]}" width="{inner[2]}" height="{inner[3]}" rx="{inner_r}"/></clipPath>'
    ),
    "stand.svg": svg(
        f'<rect x="{fx + W / 2 - STAND_W / 2}" y="{fy + H + STAND_GAP}" width="{STAND_W}" height="{STAND_H}" rx="{STAND_H / 2}" fill="#FFFFFF"/>'
    ),
}

icon = {
    "fill": {
        "linear-gradient": [
            "display-p3:0.47843,0.40000,1.00000,1.00000",
            "display-p3:0.11765,0.61176,1.00000,1.00000",
        ],
        "orientation": {"start": {"x": 0.3, "y": 0}, "stop": {"x": 0.7, "y": 1}},
    },
    "groups": [
        {
            "name": "Display",
            "layers": [
                {"name": "Bezel", "image-name": "bezel.svg"},
                {"name": "Screen", "image-name": "screen.svg", "glass": False},
                {"name": "Stand", "image-name": "stand.svg"},
            ],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0},
        },
        {
            "name": "Twin",
            # Glass softens thin strokes into a solid outline; keep the dashes crisp.
            "layers": [{"name": "Twin", "image-name": "twin.svg", "glass": False}],
            "shadow": {"kind": "neutral", "opacity": 0.3},
            "translucency": {"enabled": False, "value": 0},
        },
    ],
    "supported-platforms": {"squares": ["macOS"]},
}

assets = PACKAGE / "Assets"
assets.mkdir(parents=True, exist_ok=True)
for name, content in layers.items():
    (assets / name).write_text(content)
(PACKAGE / "icon.json").write_text(json.dumps(icon, indent=2))
print(f"wrote {PACKAGE}")
