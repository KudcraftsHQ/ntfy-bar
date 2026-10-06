# ntfy-bar — logo assets

Chosen direction: **D2 · the tile wearing its badge**. A soft cream tile, cropped by the
canvas and leaning right, with a coral notification badge pushing past the top edge.
Generated with GPT Image 2 through the `codex` bridge, in the same mascot-as-logo
treatment as Rapor Toko. Review: https://notes.kudcrafts.com/d/ntfy-mascot-logo

## Layout

```
source/D2-original.png   the untouched 1024 × 1024 generated master
icon/macos/              the macOS icon grid: 824px body, rounded, drop shadow (= AppIcon.icns)
icon/rounded/            full-bleed, rounded rectangle r = 22.37%
icon/square/             full-bleed, no mask
tray/                    the menu-bar glyph as SVG: idle, unread, off
colors.json
```

Each `icon/*` directory has `1024, 512, 256, 180, 128, 64, 32, 16`. Rebuild everything,
including `Resources/AppIcon.icns`, with `python3 scripts/make-icon.py`.

## Tray glyph

The menu bar can't use the raster mascot: it must be one colour (a template image macOS
tints for light and dark bars) and legible at 18 pt. So the glyph is a vector redraw of
the same character, drawn in code by `Sources/NtfyBar/MascotGlyph.swift`. The SVGs here
are its reference and must stay in step with it.

| State | When | Drawing |
|---|---|---|
| idle | connected, nothing unread | outlined tile, eyes open |
| unread | connected, unread > 0 (count shown beside it) | filled tile, eyes cut out, badge on the corner |
| off | not configured, or auth error | outlined tile, eyes closed |

## Palette

| Token | Hex | Role |
|---|---|---|
| `tile` | `#FEF8E8` | the character |
| `ink` | `#0A4F4D` | eyes and mouth |
| `teal` | `#2A9483` | background |
| `badge` | `#FC715D` | the notification badge, and nothing else |
