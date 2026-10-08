#!/usr/bin/env python3
# Copyright 2026 openduo
# SPDX-License-Identifier: FSL-1.1-Apache-2.0
"""The 多多随身 app icon: a line-drawn curly pompom around bold voice bars.

Usage: python3 docs/design/icon/final/src/build.py
Writes, from the geometry below (the source of truth):
  docs/design/icon/final/layers/<appearance>/<n>-<name>.svg   Icon Composer layers (flat, transparent)
  docs/design/icon/final/<appearance>-1024.{svg,png}           flat masters, no alpha, no glass
  docs/design/icon/final/preview-<appearance>.png              masters with an approximate glass look
  App/Assets.xcassets/AppIcon.appiconset/                      the app's icon (any, dark, tinted)
Requires Python 3 with Pillow and Playwright (Chromium).
"""
import json
import math
import pathlib

from PIL import Image
from playwright.sync_api import sync_playwright

SRC = pathlib.Path(__file__).resolve().parent
OUT = SRC.parent
REPO = OUT.parents[3]
APPICON = REPO / "App" / "Assets.xcassets" / "AppIcon.appiconset"
S = 1024

# Colours (openduo-design tokens; pink is the logo tongue, softened).
CREAM = ("#fdfbf4", "#ece6d6")  # light ground, top to bottom
NIGHT = ("#161615", "#050505")  # dark ground
MONO = ("#2a2a2a", "#111111")  # tinted ground; iOS tints by luminance
INK = "#1c1c1a"
PAPER = "#faf9f5"
TEAL = "#1fd9de"
PINK = "#ee7fae"
PINK_SOFT = "#f7a8c8"
CHARCOAL = "#3a3835"

# Pompom: a core circle and seven lobes mirrored on the vertical axis, larger at the top.
CX, CY, CORE = 512, 516, 282
LOBES = [(0, 174, 197), (52, 164, 199), (104, 154, 197), (156, 141, 190)]  # (deg from top, radius, distance)
SOFTEN = 0.6  # lobe depth kept in the outline; full depth reads as a cloud
SMOOTH = 24  # samples each side (of 1440) averaged to round the inward corners
INSET = 0.95  # outline radius scale, so the stroke stays inside the solid silhouette
OUTLINE_W = 46  # stroke weight on the 1024 master: about 2.6 px at 29 pt @2x
# Voice bars: centred, waveform rhythm, the last one pink.
BAR_XS = (312, 412, 512, 612, 712)
BAR_HS = (124, 214, 302, 214, 124)
BAR_CY = 534
BAR_W = 76
BAR_SHRINK = 0.8  # bar length as a share of the rhythm height, before the round caps


def circles():
    out = [(CX, CY, CORE)]
    for ang, r, d in LOBES:
        for side in ((1,) if ang == 0 else (1, -1)):
            a = math.radians(ang) * side
            out.append((CX + d * math.sin(a), CY - d * math.cos(a), r))
    return out


def outline_points(n=1440):
    """The union edge of the circles by angle (star-shaped about the centre), softened and smoothed."""
    radii, dirs = [], []
    for i in range(n):
        t = 2 * math.pi * i / n
        dx, dy = math.sin(t), -math.cos(t)
        best = 0.0
        for x, y, r in circles():
            ox, oy = CX - x, CY - y
            b = ox * dx + oy * dy
            disc = b * b - (ox * ox + oy * oy - r * r)
            if disc >= 0:
                best = max(best, -b + math.sqrt(disc))
        radii.append(best)
        dirs.append((dx, dy))
    mean = sum(radii) / n
    radii = [mean + SOFTEN * (r - mean) for r in radii]
    radii = [sum(radii[(i + k) % n] for k in range(-SMOOTH, SMOOTH + 1)) / (2 * SMOOTH + 1) for i in range(n)]
    return [(CX + r * INSET * dx, CY + r * INSET * dy) for r, (dx, dy) in zip(radii, dirs)]


OUTLINE_D = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in outline_points()) + "Z"


def doc(body, defs=""):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}">'
        f"<defs>{defs}</defs>{body}</svg>"
    )


def ground(colours):
    top, bot = colours
    return (
        f'<rect width="{S}" height="{S}" fill="url(#g)"/>',
        f'<linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{top}"/>'
        f'<stop offset="1" stop-color="{bot}"/></linearGradient>',
    )


def outline(colour):
    return (
        f'<path d="{OUTLINE_D}" fill="none" stroke="{colour}" stroke-width="{OUTLINE_W}" '
        f'stroke-linejoin="round" stroke-linecap="round"/>'
    )


def bars(colour, end):
    out = ""
    for i, (x, h) in enumerate(zip(BAR_XS, BAR_HS)):
        hh = (h * BAR_SHRINK - BAR_W) / 2
        c = end if i == len(BAR_XS) - 1 else colour
        out += f'<path d="M {x} {BAR_CY - hh:.1f} V {BAR_CY + hh:.1f}" stroke="{c}" stroke-width="{BAR_W}" stroke-linecap="round"/>'
    return out


APPEARANCES = {
    # name: (ground, [(layer name, svg), ...] back to front)
    "light": (CREAM, [("outline", outline(INK)), ("voice", bars(INK, PINK))]),
    "dark": (
        NIGHT,
        [("coat", f'<path d="{OUTLINE_D}" fill="{CHARCOAL}"/>'), ("outline", outline(PAPER)), ("voice", bars(TEAL, PINK_SOFT))],
    ),
    "tinted": (MONO, [("outline", outline("#ffffff")), ("voice", bars("#ffffff", "#8a8a8a"))]),
}

GLASS = (
    '<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".22"/>'
    '<stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>'
    '<filter id="lift" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
    '<feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#000" flood-opacity=".22"/></filter>'
)


def main() -> None:
    APPICON.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": S, "height": S})

        def render(svg_path, png_path):
            page.goto(svg_path.as_uri())
            page.screenshot(path=str(png_path))
            Image.open(png_path).convert("RGB").save(png_path)  # no alpha

        for name, (colours, layers) in APPEARANCES.items():
            ld = OUT / "layers" / name
            ld.mkdir(parents=True, exist_ok=True)
            for old in ld.glob("*.svg"):
                old.unlink()
            bg, defs = ground(colours)
            (ld / "0-background.svg").write_text(doc(bg, defs))
            for i, (lname, body) in enumerate(layers, start=1):
                (ld / f"{i}-{lname}.svg").write_text(doc(body))
            flat = OUT / f"{name}-1024.svg"
            flat.write_text(doc(bg + "".join(b for _, b in layers), defs))
            render(flat, OUT / f"{name}-1024.png")
            preview = SRC / f"preview-{name}.svg"
            preview.write_text(
                doc(
                    bg + "".join(f'<g filter="url(#lift)">{b}</g>' for _, b in layers) + f'<rect width="{S}" height="{S}" fill="url(#sheen)"/>',
                    defs + GLASS,
                )
            )
            render(preview, OUT / f"preview-{name}.png")
            preview.unlink()
            (APPICON / f"AppIcon-{name}-1024.png").write_bytes((OUT / f"{name}-1024.png").read_bytes())
        browser.close()

    images = []
    for name, appearance in (("light", None), ("dark", "dark"), ("tinted", "tinted")):
        entry = {"filename": f"AppIcon-{name}-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        images.append(entry)
    (APPICON / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
    )


if __name__ == "__main__":
    main()
