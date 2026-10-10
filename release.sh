#!/bin/sh
# Builds a universal (Apple Silicon + Intel) ShapeDesk.app and zips it as
# dist/ShapeDesk.zip for a GitHub release.
set -e
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

APP=build/ShapeDesk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/ShapeDesk" "$APP/Contents/MacOS/ShapeDesk"

# The executable's deployment target (macOS 13) is stamped into
# LC_BUILD_VERSION's `sdk` field instead of the SDK it was actually built
# with. AppKit reads that stamp for linked-on-or-after behavior, so the app
# renders with legacy control metrics — bordered buttons clamp to a fixed
# height and the Shapes grid crunches. Restamp it with the real SDK so the
# controls look right on current macOS.
SDK_VERS="$(xcrun --sdk macosx --show-sdk-version)"
MINOS_VERS="$(vtool -show-build "$APP/Contents/MacOS/ShapeDesk" | awk '/minos/{print $2; exit}')"
vtool -set-build-version macos "$MINOS_VERS" "$SDK_VERS" \
    -output "$APP/Contents/MacOS/ShapeDesk.stamped" "$APP/Contents/MacOS/ShapeDesk"
mv "$APP/Contents/MacOS/ShapeDesk.stamped" "$APP/Contents/MacOS/ShapeDesk"

cp Info.plist "$APP/Contents/Info.plist"
./icon.sh "$APP" || { echo "error: could not compile AppIcon.icon (needs Xcode 26 or later)" >&2; exit 1; }

# Without a Developer ID this is an ad-hoc signature. It still has to cover
# the whole bundle: an unsealed Info.plist makes Gatekeeper report the
# downloaded app as "damaged" instead of offering "Open Anyway".
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

mkdir -p dist
rm -f dist/ShapeDesk.zip
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" dist/ShapeDesk.zip

lipo -info "$APP/Contents/MacOS/ShapeDesk"
shasum -a 256 dist/ShapeDesk.zip
echo "Built dist/ShapeDesk.zip"
