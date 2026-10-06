# ShapeDesk

A macOS menu bar app that arranges your real desktop icons into shapes —
heart, circle, star, spiral, wave — or spells out a word with them. Icons
morph smoothly into formation, and everything is reversible.

<p align="center">
  <a href="docs/demo.mp4">
    <img src="docs/demo.webp" width="100%" alt="Real desktop folder icons arranging themselves into a heart, circle, star, spiral and wave, then spelling HELLO">
  </a>
</p>
<p align="center"><a href="docs/demo.mp4"><b>▶ Watch the full 30-second demo with sound</b></a></p>

**Website and download:** [shapedesk.space](https://shapedesk.space)

## Build & run

```sh
./bundle.sh          # builds build/ShapeDesk.app
open build/ShapeDesk.app
```

To make a release build, run `./release.sh`. It builds a universal
(Apple Silicon + Intel) app, ad-hoc signs it, and writes
`dist/ShapeDesk.zip` for a GitHub release. The website's download button
always points at the `ShapeDesk.zip` asset of the latest release.

The app icon is `AppIcon.icon`, an Icon Composer document (open it in
Icon Composer, which comes with Xcode 26). `icon.sh` compiles it into the
app: `Assets.car` for current macOS plus an `AppIcon.icns` fallback.
Without Xcode 26 or later, `bundle.sh` builds the app without an icon and
`release.sh` stops.

## Website

`website/` is the static site for shapedesk.space, deployed on Vercel with
`website/` as the project root (no build step). Its playground runs
JavaScript ports of `Geometry.swift` and `TextShape.swift` in
`website/js/`; keep them in step when the shape math changes. Preview it
locally with `python3 -m http.server -d website 8000`.

A grid icon appears in your menu bar. Click it, pick a shape, done.
"Reset to grid" puts everything back into a normal sorted grid.

## AI sorting with ShapeDesk Pro

AI Sort is bundled into the app and uses a vendor-managed Jev integration.
Customers subscribe to **ShapeDesk Pro for $5 USD/month**, including **1,000 AI
checks per UTC calendar month**, shared across up to **3 Macs**. Subscribe from
Account, complete Stripe Checkout, and return to the app to activate. A recovery
key in Account restores access on another Mac. Customers never supply a TypeSafe
API key. Customer credentials stay in macOS Keychain; the Jev key stays on the backend.

The paid service implementation and setup are in [server/README.md](server/README.md).
The service runs at `https://api.shapedesk.space`, with a separate Stripe test
environment. **Live purchases remain disabled pending a full live Stripe secret
key**; the connected CLI's saved live key is masked and cannot authenticate the
server. Server-granted owner access uses the same hosted classifier and quota.
Desktop shapes remain free, and local undo works without an active subscription
or network connection. See the server README for deployment and verification status.

### Finder integration

AI Sort follows Finder. With Finder in front, **Open AI Sort** in the menu
bar targets the folder of the active Finder window. If the desktop has
focus, no Finder window is open, or you were in another app, it targets the
Desktop. While the AI Sort window is open, switching from Finder back to it
checks Finder's active folder again, unless a sort or undo is running.
Opening a category folder such as Docs inside the current target keeps that
target, so its results and undo stay put. AI Sort follows visible folders in
your home folder (in `~/Library`, only iCloud Drive and
`~/Library/CloudStorage`) and on other drives. Hidden folders, app bundles,
system folders such as `/Applications`, and views such as Recents fall back
to the Desktop. To sort the Desktop instead of a folder, click
**Use Desktop**.

Install `ShapeDesk.app` in `/Applications` or `~/Applications` and launch it.
Select files from a single folder, or select one folder, then right-click and
choose **Services → Sort with ShapeDesk** (also in Finder's **Finder → Services**
menu). The app opens an AI Sort window showing the selected scope. Click **Sort
selection** (or **Sort folder**) to begin. Selecting a folder considers only
its immediate files. Selections spanning multiple folders, aliases, hidden
items and app packages are rejected. File and folder identities are checked
again before processing. Files or a folder you pick this way stay the
target until you click **Use Desktop** or open AI Sort from the menu bar
again.

If the service is disabled, enable it in System Settings → Keyboard → Keyboard
Shortcuts → Services → Files and Folders. Relaunch the installed app to refresh
service registration. Services use the native macOS mechanism. ShapeDesk asks
Finder for its active folder only when AI Sort opens or you switch back to it;
it does not monitor Finder folders or install a sync extension.

Click **Sort Desktop** to start an automatic sorting pass. The app sends each
file's name, extension, byte size, inferred content type/MIME type, creation
date and modification date through the ShapeDesk service to the
[TypeSafe Jev Choice API](https://docs.typesafe.ai/api). File contents and full
paths are not sent. The integration pins `jev-1.13.0` so a model alias update
cannot silently change file-moving decisions.

The exact choices are **Screenshots, Recordings, Videos, Audio, Images, Docs,
Code, Other**. Only a valid answer with **`confidence > 0.8`** moves a file;
exactly `0.8`, lower confidence, malformed answers and processing errors all
leave the file in place. The returned `confidence` is used directly, rather
than the winning option's probability. Other files continue after a file fails.

- Each pass scans only visible regular files directly in the chosen folder
  (the Desktop, unless AI Sort follows a Finder folder or you pick one
  with Services). Directories, packages, symbolic links and Finder aliases
  are excluded. Category directories are created as needed and are never
  recursively scanned.
- The panel updates scanned, moved and skipped totals, progress, and moved/skipped
  counts for each category. Skips without a classification appear as Unclassified.
  **Stop** cancels outstanding network work and leaves remaining files untouched.
- Collisions receive numbered filenames, such as `report (1).pdf`. Atomic
  exclusive renames refuse to overwrite any existing file, directory or link,
  including one created concurrently. The same protection applies during undo.
- Immutable/read-only files, advisory-locked files, open files reported by macOS,
  incomplete downloads, undownloaded iCloud files, hard links and files modified
  in the last two seconds are left alone. Identity, size and modification time
  are checked again after classification. Category directory links are refused.
- **Undo last sort** restores the latest pending sorting pass. Undo survives app
  restarts, preserves newly created desktop files using collision names, and
  allows retrying files that could not be restored. It checks file identities so
  a replacement file with the same name is not moved. Empty category folders remain.

Each move and undo first writes and syncs an intent record in
`~/Library/Application Support/ShapeDesk/SortHistory`. These records recover
interrupted operations by checking the recorded file identity at the source and
destination. History write failures prevent the corresponding move; unreadable
history blocks new sorts while preserving the existing records. A filesystem
lock excludes concurrent sorting/undo across app instances.

Sorting runs when requested; it does not continuously watch Desktop. Open-file
detection is a bounded `lsof` check plus a nonblocking advisory lock. As with other
macOS file tools, an uncooperative process can open or change a file after the last
check; there is no OS-wide mandatory lock against every writer. Cross-volume moves
fail safely instead of falling back to copy-and-delete. Model accuracy depends on
the metadata available; a confidence threshold does not guarantee a correct category.

macOS may ask for access to the selected Desktop, Documents or Downloads
folder. AI sorting moves files with filesystem access directly; the Finder
Automation permission arranges icons into shapes and lets AI Sort ask Finder
which folder is active. Without it, AI Sort targets the Desktop.

## Tests

```sh
swift test --enable-code-coverage
```

Tests use disposable temporary desktops and a mocked TypeSafe transport. They
cover the strict confidence boundary (including nonfinite/invalid scores), all
eight categories, request/response validation, rate limits and cancellation,
shallow/hidden-file filtering, metadata changes, locks and open files, Unicode
filenames, competing writers, journal failures, restart recovery, partial undo,
and concurrent sorter instances. Tests never sort your actual desktop or require
a TypeSafe key. Hosted-client tests cover credential boundaries, transport replay,
quota denial and subscription-independent undo. Finder tests cover file
selections, shallow folder scans, replacement identity checks and which
Finder folders AI Sort follows. Run `npm --prefix server run
test:postgres` for the backend's real-database concurrency and metering tests.
Live model quality and checkout/account authentication require the deployed service
and your configured provider accounts.

## Requirements

- macOS 13 or later, Apple Silicon or Intel (Swift toolchain to build;
  Xcode 26 or later to include the app icon).
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
   (`TextShape.swift`) draws the word in capitals with a thin font, thins
   the strokes to one-pixel centerlines, puts icons on stroke ends and
   corners first, then spaces the rest evenly along the strokes. Words read
   best with about 7 or more icons per letter; the status line says so when
   a word is too long for your icon count.
2. **Finder bridge** (`FinderBridge.swift`): icon names and positions are
   read with AppleScript (`desktop position of every item of desktop`), and
   positions are written back in one `osascript` call per arrangement:
   14 smoothstep-eased frames, each frame's moves sent without waiting for
   Finder's replies, then one quick query so Finder catches up before the
   next frame. That takes about 1.2 s for 40 icons; waiting for a reply to
   every move took about 10 s.
3. **UI** (`ShapeDeskApp.swift`, `MenuBarPanel.swift`): a menu bar icon
   with a drop-down panel holding the shape grid, text field, size slider,
   and status line. The app positions the panel itself each time it opens,
   just under the icon (or under the click if macOS reports the icon
   somewhere odd) and always inside the screen. SwiftUI's `MenuBarExtra`
   trusted the reported icon position and could open off-screen.

If icons end up tighter than ~64 px apart (lots of icons, small screen),
the status line warns that they may overlap — raise the **Size** slider.

## Notes

- Icon names come from Finder and are matched back by name; two files with
  identical names on the desktop would both target the same icon (Finder
  normally prevents this).
- Animation needs to read current positions first; if the read fails it
  falls back to placing icons instantly.
