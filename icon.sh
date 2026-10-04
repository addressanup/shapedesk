#!/bin/sh
# Compiles AppIcon.icon (Icon Composer) into the given .app bundle:
# Assets.car, which macOS reads first, plus AppIcon.icns as a fallback.
# An app with only an .icns gets shrunk into a grey squircle on macOS 26.
# Needs Xcode 26 or later; exits non-zero if the icon could not be built.
set -e

mkdir -p "$1/Contents/Resources"
RES="$(cd "$1/Contents/Resources" && pwd -P)"
ICON="$(cd "$(dirname "$0")" && pwd -P)/AppIcon.icon"
rm -f "$RES/Assets.car" "$RES/AppIcon.icns"

xcrun --find actool >/dev/null 2>&1 || exit 1
TMP="$(mktemp -d)"
# Paths must be absolute: actool hands the work to a helper process that
# resolves relative paths against its own, possibly stale, directory.
xcrun actool "$ICON" --compile "$RES" \
    --app-icon AppIcon --enable-on-demand-resources NO \
    --development-region en --target-device mac --platform macosx \
    --minimum-deployment-target 13.0 \
    --output-partial-info-plist "$TMP/partial.plist" \
    --output-format human-readable-text --errors --warnings >"$TMP/actool.log" 2>&1 || true

# actool exits 0 even when it fails, so check what it reported and wrote.
if ! grep -q 'actool.errors' "$TMP/actool.log" && [ -f "$RES/Assets.car" ] && [ -f "$RES/AppIcon.icns" ]; then
    rm -rf "$TMP"
    exit 0
fi
cat "$TMP/actool.log" >&2
rm -f "$RES/Assets.car" "$RES/AppIcon.icns"
rm -rf "$TMP"
exit 1
