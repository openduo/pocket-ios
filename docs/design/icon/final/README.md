# App icon

A line-drawn curly pompom (the poodle coat) around bold voice bars (hold to talk). No face.
`src/build.py` is the source of truth; everything else in this folder and the app's
`AppIcon.appiconset` is generated from it.

| Appearance | Ground (top → bottom) | Outline | Bars | Last bar | Fill inside outline |
|---|---|---|---|---|---|
| light | `#fdfbf4` → `#ece6d6` | `#1c1c1a` | `#1c1c1a` | `#ee7fae` | none |
| dark | `#161615` → `#050505` | `#faf9f5` | `#1fd9de` | `#f7a8c8` | `#3a3835` |
| tinted | `#2a2a2a` → `#111111` | `#ffffff` | `#ffffff` | `#8a8a8a` | none |

Geometry on the 1024 canvas:

- Pompom: core circle r 282 at (512, 516) plus seven lobes mirrored on the vertical axis
  (degrees from top, radius, distance): (0, 174, 197), (±52, 164, 199), (±104, 154, 197), (±156, 141, 190).
- Outline: the union edge with lobe depth kept at 60 %, inward corners averaged over ±24 of 1440
  samples, radius scaled to 0.95; stroke 46 with round joins. At full lobe depth the outline reads as
  a cloud.
- Bars: five round-capped strokes, width 76, at x 312–712 step 100, centred on y 534; rhythm heights
  124 / 214 / 302 / 214 / 124, drawn at 80 % of each height before the caps.

Outputs:

- `layers/<appearance>/<n>-<name>.svg`: flat layers on transparent canvases, back to front, for
  Icon Composer (background, then coat for dark, outline, voice).
- `<appearance>-1024.{svg,png}`: flat masters, RGB without alpha. These are the app icon.
- `preview-<appearance>.png`: the masters with an approximate glass sheen and shadow, for review only.

Regenerate (Python 3 with Pillow and Playwright/Chromium):

```sh
python3 docs/design/icon/final/src/build.py
```

Earlier design rounds are not part of the repository.
