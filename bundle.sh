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

echo "Built $APP"
echo "Run it with:  open \"$APP\""
