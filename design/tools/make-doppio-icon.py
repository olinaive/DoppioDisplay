"""Generates the Doppio app icon as SVG with exact geometry.

Usage: python3 design/tools/make-doppio-icon.py   (writes design/doppio-icon*.svg)
Everything is on the 1024 macOS icon grid: body 824×824 at (100, 100).
"""
import math
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent


def squircle(cx, cy, size, n=5.0, steps=720):
    """Superellipse |x|^n + |y|^n = 1, the continuous-corner shape of macOS icons."""
    a = size / 2
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = a * math.copysign(abs(c) ** (2 / n), c)
        y = a * math.copysign(abs(s) ** (2 / n), s)
        pts.append(f"{cx + x:.2f},{cy + y:.2f}")
    return "M" + " L".join(pts) + " Z"


def rounded_rect_from_top_center(x, y, w, h, r):
    """Rounded rect path that starts at the middle of the top edge (for symmetric dashes)."""
    k = 0.5523 * r  # cubic approximation of a quarter circle
    return (
        f"M{x + w / 2:.2f},{y:.2f} H{x + w - r:.2f} "
        f"C{x + w - r + k:.2f},{y:.2f} {x + w:.2f},{y + r - k:.2f} {x + w:.2f},{y + r:.2f} "
        f"V{y + h - r:.2f} "
        f"C{x + w:.2f},{y + h - r + k:.2f} {x + w - r + k:.2f},{y + h:.2f} {x + w - r:.2f},{y + h:.2f} "
        f"H{x + r:.2f} "
        f"C{x + r - k:.2f},{y + h:.2f} {x:.2f},{y + h - r + k:.2f} {x:.2f},{y + h - r:.2f} "
        f"V{y + r:.2f} "
        f"C{x:.2f},{y + r - k:.2f} {x + r - k:.2f},{y:.2f} {x + r:.2f},{y:.2f} Z"
    )


# --- Layout -------------------------------------------------------------
W, H, R = 440, 300, 44          # both screens
D = 120                          # diagonal offset between twin and real screen
BEZEL = 20
STAND_W, STAND_H, STAND_GAP = 96, 20, 22

group_w = W + D
group_h = H + D + STAND_GAP + STAND_H
x0 = 512 - group_w / 2
y0 = 512 - group_h / 2 + 4      # optical centre sits slightly low
back = (x0, y0)
front = (x0 + D, y0 + D)

# 20 dashes: with a 440×300 r44 rect, edge centres and corner midpoints all land on dash centres.
DASHES = 20
DASH_FILL = 0.62


def icon(simplified=False):
    bx, by = back
    fx, fy = front
    body = squircle(512, 512, 824)
    stroke = 34 if simplified else 14
    dashes = DASHES
    twin = rounded_rect_from_top_center(bx, by, W, H, R)
    inner_r = R - BEZEL + 4
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">',
        "<defs>",
        '<linearGradient id="bg" x1="0.15" y1="0" x2="0.85" y2="1">'
        '<stop offset="0" stop-color="#7B65FF"/><stop offset="0.55" stop-color="#4C6DFF"/><stop offset="1" stop-color="#1E9CFF"/></linearGradient>',
        '<radialGradient id="shine" cx="0.32" cy="0.08" r="0.85">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.34"/><stop offset="0.65" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>',
        '<linearGradient id="bezel" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#DCE3FF"/></linearGradient>',
        '<linearGradient id="wall" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0" stop-color="#2F45FF"/><stop offset="0.55" stop-color="#6A4DFF"/><stop offset="1" stop-color="#F06BB4"/></linearGradient>',
        '<filter id="soft" x="-20%" y="-20%" width="140%" height="160%">'
        '<feDropShadow dx="0" dy="22" stdDeviation="24" flood-color="#0A1060" flood-opacity="0.42"/></filter>',
        '<filter id="glow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="9"/></filter>',
        "</defs>",
        f'<path d="{body}" fill="url(#bg)"/>',
    ]
    if not simplified:
        parts += [
            f'<path d="{body}" fill="url(#shine)"/>',
            f'<path d="{body}" fill="none" stroke="#FFFFFF" stroke-opacity="0.26" stroke-width="3"/>',
        ]
    # Twin: frosted glass + evenly dashed edge (+ soft glow under the dashes).
    dash = f'stroke-dasharray="{DASH_FILL:.2f} {1 - DASH_FILL:.2f}" stroke-dashoffset="{DASH_FILL / 2:.2f}"'
    if not simplified:
        parts += [
            f'<path d="{twin}" fill="#FFFFFF" fill-opacity="0.16"/>',
            f'<path d="{twin}" fill="none" stroke="#FFFFFF" stroke-opacity="0.55" stroke-width="{stroke + 8}" '
            f'pathLength="{dashes}" {dash} stroke-linecap="round" filter="url(#glow)"/>',
        ]
    if simplified:
        # Dashes turn to mush at 16–32 px; a solid translucent outline reads as "the twin".
        parts.append(f'<path d="{twin}" fill="#FFFFFF" fill-opacity="0.18" stroke="#FFFFFF" stroke-opacity="0.75" stroke-width="{stroke}"/>')
    else:
        parts.append(
            f'<path d="{twin}" fill="none" stroke="#FFFFFF" stroke-opacity="0.95" stroke-width="{stroke}" '
            f'pathLength="{dashes}" {dash} stroke-linecap="round"/>'
        )
    # Real display: bezel, wallpaper, menu bar, stand.
    front_group = [
        f'<rect x="{fx}" y="{fy}" width="{W}" height="{H}" rx="{R}" fill="url(#bezel)"/>',
        f'<rect x="{fx + BEZEL}" y="{fy + BEZEL}" width="{W - 2 * BEZEL}" height="{H - 2 * BEZEL}" rx="{inner_r}" fill="url(#wall)"/>',
    ]
    if not simplified:
        front_group += [
            f'<clipPath id="screen"><rect x="{fx + BEZEL}" y="{fy + BEZEL}" width="{W - 2 * BEZEL}" height="{H - 2 * BEZEL}" rx="{inner_r}"/></clipPath>',
            f'<rect x="{fx + BEZEL}" y="{fy + BEZEL}" width="{W - 2 * BEZEL}" height="18" fill="#FFFFFF" fill-opacity="0.45" clip-path="url(#screen)"/>',
        ]
    front_group.append(
        f'<rect x="{fx + W / 2 - STAND_W / 2}" y="{fy + H + STAND_GAP}" width="{STAND_W}" height="{STAND_H}" rx="{STAND_H / 2}" fill="#FFFFFF" fill-opacity="0.95"/>'
    )
    parts.append(('<g filter="url(#soft)">' if not simplified else "<g>") + "".join(front_group) + "</g>")
    parts.append("</svg>")
    return "\n".join(parts)


def glyph():
    """Monochrome menu bar template (18×18 pt), same idea on a 24 grid."""
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">'
        f'<path d="{rounded_rect_from_top_center(2.5, 3.5, 12.5, 8.5, 1.9)}" fill="none" stroke="#000" stroke-width="1.6" '
        'pathLength="12" stroke-dasharray="0.62 0.38" stroke-dashoffset="0.31" stroke-linecap="round"/>'
        '<rect x="8.5" y="8.5" width="12.5" height="8.5" rx="1.9" fill="#000"/>'
        '<rect x="13.15" y="18.6" width="3.2" height="1.6" rx="0.8" fill="#000"/>'
        "</svg>"
    )


(OUT / "doppio-icon.svg").write_text(icon())
(OUT / "doppio-icon-small.svg").write_text(icon(simplified=True))
(OUT / "doppio-menubar.svg").write_text(glyph())
print("front", front, "back", back)
