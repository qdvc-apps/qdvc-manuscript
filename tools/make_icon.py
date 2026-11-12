#!/usr/bin/env python3
"""Generate the app icon: Resources/AppIcon.svg (vector master) and
Resources/AppIcon.icns (every macOS size, rendered natively from the vector).

The design is a typewriter seen from the front, whose body happens to be
exactly the macOS icon shape: the carriage ends make the top corners, a
sheet of paper (a title and lines of text, one sentence per line) rises out
of the platen to the top edge, the ribbon spools sit either side of the fan
of type bars, and four rows of round keys and a space bar fill the deck down
to the rounded bottom. The body is a glossy mint enamel, like a 1950s
portable. It keeps the family's construction (QDVC Response Letter,
Progress, Empirics…): Apple's tile, a soft glow and sheen, tinted shadows,
here with the tile itself as the object.

Geometry follows Apple's macOS icon template: a 1024x1024 canvas holding an
824x824 tile (100 px transparent margin) with a 185.4 px continuous-curvature
("squircle") corner, plus a soft drop shadow. The corner is the curve UIKit
draws for continuous corners, as reverse-engineered and published by PaintCode
(https://www.paintcodeapp.com/blogpost/code-for-ios-7-rounded-rectangles).

Usage:

    python3 tools/make_icon.py            # writes Resources/AppIcon.{svg,icns}
    python3 tools/make_icon.py --preview  # also writes build/icon-preview.png

Requires rsvg-convert (macOS: `brew install librsvg`; Debian/Ubuntu:
`apt install librsvg2-bin`). No other dependencies; the .icns is written
directly, so Apple's iconutil is not needed.
"""

import argparse
import math
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources"

# ---------------------------------------------------------------------------
# Palette: mint enamel, chrome, cream keys, black ribbon and platen.

BODY_TOP, BODY_MID, BODY_DEEP = "#CFEDE2", "#8CCBB6", "#4E9682"
BODY_SHADOW = "#2F6658"
DECK_TOP, DECK_DEEP = "#7BBCA7", "#3F8572"
CHROME_LIGHT, CHROME_DARK = "#FBFCFD", "#9AA4AE"
PLATEN, PLATEN_LIGHT = "#1E2226", "#4A525A"
PAPER, PAPER_SHADE = "#FFFEFA", "#ECE8DF"
INK, INK_TITLE = "#3C4148", "#1D2126"
KEY_CAP, KEY_CAP_SHADE = "#FFF9EC", "#E2D8C3"
KEY_LETTER = "#2B3036"
RIBBON_RED = "#C8372D"
CURSOR = "#2F7BF6"

# ---------------------------------------------------------------------------
# Apple's template geometry.

TILE_ORIGIN, TILE_SIZE, CORNER_RADIUS = 100, 824, 185.4
SHADOW_BLUR_RADIUS, SHADOW_OFFSET_Y, SHADOW_OPACITY = 28, 12, 0.5

# Continuous-corner segments around the top-right corner, in units of the
# radius: (distance from the right edge, distance from the top edge).
_CORNER = [
    ("L", (1.52866471, 0.0)),
    ("C", (1.08849323, 0.0), (0.86840689, 0.0), (0.66993427, 0.06549600)),
    ("L", (0.63149399, 0.07491100)),
    ("C", (0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491176, 0.63149399)),
    ("C", (0.0, 0.86840701), (0.0, 1.08849299), (0.0, 1.52866483)),
]


def continuous_rounded_rect(x, y, w, h, r):
    """SVG path of a rounded rectangle with Apple's continuous corners."""
    r = min(r, min(w, h) / 2 / 1.52866483)
    corners = [
        lambda u, v: (x + w - u * r, y + v * r),        # top-right
        lambda u, v: (x + w - v * r, y + h - u * r),    # bottom-right
        lambda u, v: (x + u * r, y + h - v * r),        # bottom-left
        lambda u, v: (x + v * r, y + u * r),            # top-left
    ]

    def fmt(p):
        return f"{p[0]:.2f},{p[1]:.2f}"

    d = [f"M{fmt((x + 1.52866483 * r, y))}"]
    for corner in corners:
        for seg in _CORNER:
            if seg[0] == "L":
                d.append("L" + fmt(corner(*seg[1])))
            else:
                d.append("C" + " ".join(fmt(corner(*p)) for p in seg[1:]))
    d.append("Z")
    return " ".join(d)


TILE = continuous_rounded_rect(TILE_ORIGIN, TILE_ORIGIN, TILE_SIZE, TILE_SIZE, CORNER_RADIUS)


def _paper():
    """The sheet, rising from the platen to the tile's top edge: a title and
    lines of text, each sentence on its own line, the last half-typed."""
    x0, x1 = 268, 756
    top, bottom = 100, 452
    parts = [f'<rect x="{x0}" y="{top - 40}" width="{x1 - x0}" height="{bottom - top + 40}" fill="url(#paper)"/>',
             # A faint fold shadow where the sheet bends into the platen.
             f'<rect x="{x0}" y="{bottom - 46}" width="{x1 - x0}" height="46" fill="url(#paperfold)"/>']
    # Title, centred and bold.
    parts.append(f'<rect x="{512 - 130}" y="166" width="260" height="20" rx="10" fill="{INK_TITLE}"/>')
    parts.append(f'<rect x="{512 - 80}" y="198" width="160" height="12" rx="6" fill="{INK}" fill-opacity="0.55"/>')
    # One sentence per line, ragged right.
    lines = [0.92, 0.66, 0.84, 0.48, 0.78]
    for i, frac in enumerate(lines):
        y = 236 + i * 30
        w = (x1 - x0 - 84) * frac
        parts.append(f'<rect x="{x0 + 42}" y="{y}" width="{w:.1f}" height="12" rx="6" fill="{INK}" fill-opacity="0.8"/>')
    # The line being typed, and the insertion point.
    y = 236 + len(lines) * 30
    w = (x1 - x0 - 84) * 0.36
    parts.append(f'<rect x="{x0 + 42}" y="{y}" width="{w:.1f}" height="12" rx="6" fill="{INK}" fill-opacity="0.8"/>')
    parts.append(f'<rect x="{x0 + 42 + w + 10:.1f}" y="{y - 6}" width="6" height="24" rx="3" fill="{CURSOR}"/>')
    return parts


def _carriage():
    """Platen, knobs, paper bail and the carriage-return lever."""
    parts = []
    # The platen roller across the full width, with its shine.
    parts.append('<rect x="150" y="438" width="724" height="68" rx="34" fill="url(#platen)"/>')
    parts.append('<rect x="176" y="448" width="672" height="10" rx="5" fill="#FFFFFF" fill-opacity="0.22"/>')
    # Knobs at the ends (chrome discs).
    for cx in (150, 874):
        parts.append(f'<circle cx="{cx}" cy="472" r="44" fill="url(#chrome)" stroke="{CHROME_DARK}" stroke-width="3"/>')
        parts.append(f'<circle cx="{cx}" cy="472" r="26" fill="none" stroke="{CHROME_DARK}" stroke-opacity="0.6" stroke-width="3"/>')
        for k in range(12):
            a = math.radians(k * 30)
            parts.append(f'<line x1="{cx + 30 * math.cos(a):.1f}" y1="{472 + 30 * math.sin(a):.1f}" '
                         f'x2="{cx + 40 * math.cos(a):.1f}" y2="{472 + 40 * math.sin(a):.1f}" '
                         f'stroke="{CHROME_DARK}" stroke-opacity="0.55" stroke-width="3" stroke-linecap="round"/>')
    # The paper bail with its two little rollers.
    parts.append('<rect x="236" y="404" width="552" height="12" rx="6" fill="url(#chromebar)" '
                 f'stroke="{CHROME_DARK}" stroke-opacity="0.6" stroke-width="1.5"/>')
    for cx in (360, 664):
        parts.append(f'<rect x="{cx - 22}" y="398" width="44" height="24" rx="12" fill="{PLATEN}"/>')
    # Carriage-return lever, sweeping up over the left carriage end.
    parts.append(f'<path d="M206 420 C188 360 176 300 196 238" fill="none" stroke="{CHROME_DARK}" stroke-width="20" '
                 'stroke-linecap="round"/>')
    parts.append(f'<path d="M206 420 C188 360 176 300 196 238" fill="none" stroke="url(#chromebar)" stroke-width="14" '
                 'stroke-linecap="round"/>')
    parts.append(f'<circle cx="198" cy="232" r="17" fill="url(#chrome)" stroke="{CHROME_DARK}" stroke-width="3"/>')
    return parts


def _basket():
    """The window onto the type bars, with the ribbon spools either side."""
    parts = []
    cx, cy = 512, 640
    parts.append(f'<path d="M{cx - 196} {cy} A196 118 0 0 1 {cx + 196} {cy} Z" fill="url(#basket)"/>')
    # Type bars fanning out from the type guide to the rim of the window.
    for k in range(19):
        t = math.radians(14 + k * (152 / 18))
        x2, y2 = cx + 184 * math.cos(t), cy - 108 * math.sin(t)
        parts.append(f'<line x1="{cx}" y1="{cy - 4}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{CHROME_DARK}" '
                     'stroke-width="4" stroke-linecap="round" stroke-opacity="0.9"/>')
    parts.append(f'<path d="M{cx - 196} {cy} A196 118 0 0 1 {cx + 196} {cy}" fill="none" stroke="{BODY_SHADOW}" '
                 'stroke-opacity="0.5" stroke-width="5"/>')
    # The type guide and the ribbon in front of it (black over red).
    parts.append(f'<rect x="{cx - 54}" y="{cy - 92}" width="108" height="14" rx="4" fill="{PLATEN}"/>')
    parts.append(f'<rect x="{cx - 54}" y="{cy - 85}" width="108" height="7" rx="3" fill="{RIBBON_RED}"/>')
    # Ribbon spools.
    for sx in (276, 748):
        parts.append(f'<circle cx="{sx}" cy="590" r="58" fill="url(#chrome)" stroke="{CHROME_DARK}" stroke-width="3"/>')
        parts.append(f'<circle cx="{sx}" cy="590" r="42" fill="{PLATEN}"/>')
        parts.append(f'<circle cx="{sx}" cy="590" r="42" fill="none" stroke="{RIBBON_RED}" stroke-width="7" stroke-opacity="0.85"/>')
        parts.append(f'<circle cx="{sx}" cy="590" r="12" fill="url(#chrome)"/>')
    return parts


def _keyboard():
    """Four staggered rows of round keys and the space bar."""
    parts = []
    parts.append('<path d="M100 716 Q512 684 924 716 L924 924 L100 924 Z" fill="url(#deck)"/>')
    rows = [(746, 10, -24), (806, 10, 4), (866, 9, 30)]
    letters = ["QWERTYUIOP", "ASDFGHJKL;", "ZXCVBNM,."]
    pitch = 66
    for (y, count, offset), row in zip(rows, letters):
        start = 512 - (count - 1) * pitch / 2 + offset
        for i in range(count):
            x = start + i * pitch
            parts.append(f'<circle cx="{x:.1f}" cy="{y + 5}" r="27" fill="{BODY_SHADOW}" fill-opacity="0.45"/>')
            parts.append(f'<circle cx="{x:.1f}" cy="{y}" r="27" fill="url(#chrome)" stroke="{CHROME_DARK}" stroke-width="2"/>')
            parts.append(f'<circle cx="{x:.1f}" cy="{y}" r="21" fill="url(#keycap)"/>')
            parts.append(f'<text x="{x:.1f}" y="{y + 7.5}" font-family="Georgia, Times New Roman, serif" '
                         f'font-size="21" font-weight="bold" text-anchor="middle" fill="{KEY_LETTER}">{row[i]}</text>')
    # Space bar.
    parts.append(f'<rect x="300" y="{896}" width="424" height="22" rx="11" fill="url(#chromebar)" '
                 f'stroke="{CHROME_DARK}" stroke-width="2"/>')
    return parts


def icon_svg():
    sigma = SHADOW_BLUR_RADIUS / 2
    defs = [
        f'<linearGradient id="body" x1="0" y1="0" x2="0.25" y2="1">'
        f'<stop offset="0" stop-color="{BODY_TOP}"/><stop offset="0.45" stop-color="{BODY_MID}"/>'
        f'<stop offset="1" stop-color="{BODY_DEEP}"/></linearGradient>',
        f'<linearGradient id="deck" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{DECK_TOP}"/><stop offset="1" stop-color="{DECK_DEEP}"/></linearGradient>',
        '<radialGradient id="glow" cx="0.28" cy="0.16" r="0.8">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.42"/>'
        '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>',
        '<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.18"/>'
        '<stop offset="0.40" stop-color="#FFFFFF" stop-opacity="0.03"/>'
        '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>',
        '<linearGradient id="edge" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.85"/>'
        '<stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.15"/>'
        '<stop offset="1" stop-color="#FFFFFF" stop-opacity="0.35"/></linearGradient>',
        f'<linearGradient id="paper" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{PAPER}"/>'
        f'<stop offset="1" stop-color="{PAPER_SHADE}"/></linearGradient>',
        '<linearGradient id="paperfold" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#000000" stop-opacity="0"/>'
        '<stop offset="1" stop-color="#000000" stop-opacity="0.18"/></linearGradient>',
        f'<linearGradient id="platen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{PLATEN_LIGHT}"/>'
        f'<stop offset="0.45" stop-color="{PLATEN}"/><stop offset="1" stop-color="#0E1012"/></linearGradient>',
        f'<radialGradient id="chrome" cx="0.35" cy="0.3" r="0.8"><stop offset="0" stop-color="{CHROME_LIGHT}"/>'
        f'<stop offset="0.6" stop-color="#D3D9DF"/><stop offset="1" stop-color="{CHROME_DARK}"/></radialGradient>',
        f'<linearGradient id="chromebar" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{CHROME_LIGHT}"/>'
        f'<stop offset="1" stop-color="{CHROME_DARK}"/></linearGradient>',
        f'<radialGradient id="keycap" cx="0.4" cy="0.35" r="0.75"><stop offset="0" stop-color="#FFFFFF"/>'
        f'<stop offset="0.5" stop-color="{KEY_CAP}"/><stop offset="1" stop-color="{KEY_CAP_SHADE}"/></radialGradient>',
        '<radialGradient id="basket" cx="0.5" cy="1" r="1">'
        f'<stop offset="0" stop-color="#3A4148"/><stop offset="1" stop-color="{PLATEN}"/></radialGradient>',
        f'<clipPath id="clip"><path d="{TILE}"/></clipPath>',
        '<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">'
        f'<feGaussianBlur in="SourceAlpha" stdDeviation="{sigma}"/><feOffset dy="{SHADOW_OFFSET_Y}"/>'
        f'<feComponentTransfer><feFuncA type="linear" slope="{SHADOW_OPACITY}"/></feComponentTransfer>'
        '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
        '<filter id="objshadow" x="-30%" y="-30%" width="160%" height="160%">'
        '<feGaussianBlur in="SourceAlpha" stdDeviation="9"/><feOffset dx="0" dy="9"/>'
        f'<feFlood flood-color="{BODY_SHADOW}" flood-opacity="0.45"/><feComposite operator="in" in2="SourceAlpha"/>'
        '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
    ]
    parts = [
        f'<g filter="url(#shadow)"><path d="{TILE}" fill="url(#body)"/></g>',
        '<g clip-path="url(#clip)">',
        '<rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>',
        # The carriage's side covers, either side of the paper.
        '<rect x="100" y="100" width="168" height="372" fill="#FFFFFF" fill-opacity="0.10"/>',
        '<rect x="756" y="100" width="168" height="372" fill="#000000" fill-opacity="0.04"/>',
        '<rect x="262" y="100" width="6" height="372" fill="#000000" fill-opacity="0.06"/>',
        '<rect x="756" y="100" width="6" height="372" fill="#000000" fill-opacity="0.06"/>',
        # The body's shoulders below the carriage, a gentle step down.
        f'<path d="M100 520 Q512 486 924 520 L924 924 L100 924 Z" fill="{BODY_DEEP}" fill-opacity="0.18"/>',
        '<g filter="url(#objshadow)">', *_paper(), '</g>',
        '<g filter="url(#objshadow)">', *_carriage(), '</g>',
        '<g filter="url(#objshadow)">', *_basket(), '</g>',
        '<g filter="url(#objshadow)">', *_keyboard(), '</g>',
        '<rect x="100" y="100" width="824" height="824" fill="url(#sheen)"/>',
        '</g>',
        f'<path d="{TILE}" fill="none" stroke="url(#edge)" stroke-width="6"/>',
    ]
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<defs>{"".join(defs)}</defs>{"".join(parts)}</svg>\n')

# ---------------------------------------------------------------------------
# .icns writing. These are the element types `iconutil` emits for a standard
# .iconset; all of them hold PNG data.

ICNS_ELEMENTS = [
    ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64),
    ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512),
    ("ic09", 512), ("ic10", 1024),
]


def render_png(svg_path, size, out_path):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), str(svg_path), "-o", str(out_path)],
                   check=True)


def write_icns(pngs_by_size, out_path):
    chunks = b""
    for code, size in ICNS_ELEMENTS:
        data = pngs_by_size[size]
        chunks += code.encode("ascii") + struct.pack(">I", len(data) + 8) + data
    out_path.write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)


def main():
    parser = argparse.ArgumentParser(description="Generate Resources/AppIcon.svg and AppIcon.icns.")
    parser.add_argument("--preview", action="store_true",
                        help="also write build/icon-preview.png (1024 px)")
    args = parser.parse_args()

    try:
        subprocess.run(["rsvg-convert", "--version"], check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError):
        sys.exit("error: rsvg-convert not found (macOS: brew install librsvg)")

    RESOURCES.mkdir(exist_ok=True)
    svg_path = RESOURCES / "AppIcon.svg"
    svg_path.write_text(icon_svg())

    with tempfile.TemporaryDirectory() as tmp:
        pngs = {}
        for size in sorted({s for _, s in ICNS_ELEMENTS}):
            png = Path(tmp) / f"icon_{size}.png"
            render_png(svg_path, size, png)
            pngs[size] = png.read_bytes()
        write_icns(pngs, RESOURCES / "AppIcon.icns")

    if args.preview:
        (ROOT / "build").mkdir(exist_ok=True)
        render_png(svg_path, 1024, ROOT / "build" / "icon-preview.png")
    print(f"Wrote {svg_path.relative_to(ROOT)} and Resources/AppIcon.icns")


if __name__ == "__main__":
    main()
