# ShapeDesk

A macOS menu bar app that arranges your real desktop icons into shapes —
heart, circle, star, spiral, wave — or spells out a word with them. Icons
morph smoothly into formation, and everything is reversible.

## Build & run

```sh
./bundle.sh          # builds build/ShapeDesk.app
open build/ShapeDesk.app
```

A grid icon appears in your menu bar. Click it, pick a shape, done.
"Reset to grid" puts everything back into a normal sorted grid.

## Requirements

- macOS 13 or later, Apple Silicon or Intel (Swift toolchain to build).
- **Automation permission**: on first use macOS asks to let ShapeDesk
  control Finder — click OK. If you miss it: System Settings →
  Privacy & Security → Automation → ShapeDesk → Finder.
- **Finder desktop sorting must be off**: right-click the desktop →
  *Sort By* → *None* (and keep *Stacks* off). If sorting is on, Finder
  immediately snaps icons back, undoing the shape.
- If you use iCloud "Desktop & Documents Folders", icons live in iCloud;
  the app still works, but freshly-synced items may appear unarranged.

## How it works

1. **Shape math** (`Geometry.swift`): each shape is a parametric polyline
   (e.g. the classic `16 sin³t` heart), resampled by arc length into exactly
   one point per desktop icon, then scaled and centered on your screen's
   usable area (menu bar and Dock excluded). The text mode
   (`TextShape.swift`) renders the word into an offscreen bitmap and picks
   well-spread points inside the glyphs.
2. **Finder bridge** (`FinderBridge.swift`): icon names and positions are
   read with AppleScript (`desktop position of every item of desktop`), and
   positions are written back in a single batched `osascript` call per
   animation frame (14 smoothstep-eased frames over ~0.7 s).
3. **UI** (`ShapeDeskApp.swift`): a SwiftUI `MenuBarExtra` window with the
   shape grid, text field, size slider, and status line.

If icons end up tighter than ~64 px apart (lots of icons, small screen),
the status line warns that they may overlap — raise the **Size** slider.

## Notes

- Icon names come from Finder and are matched back by name; two files with
  identical names on the desktop would both target the same icon (Finder
  normally prevents this).
- Animation needs to read current positions first; if the read fails it
  falls back to placing icons instantly.
