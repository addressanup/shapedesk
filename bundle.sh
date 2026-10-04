#!/bin/sh
# Builds ShapeDesk and packages it as build/ShapeDesk.app
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/ShapeDesk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ShapeDesk "$APP/Contents/MacOS/ShapeDesk"
cp Info.plist "$APP/Contents/Info.plist"
if ! ./icon.sh "$APP"; then
    echo "warning: built without the app icon (compiling AppIcon.icon needs Xcode 26 or later)" >&2
fi

echo "Built $APP"
echo "Run it with:  open \"$APP\""
