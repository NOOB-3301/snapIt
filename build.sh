#!/bin/sh
# Builds build/SnapIt.app (no Xcode needed). Run: ./build.sh && open build/SnapIt.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/SnapIt.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SnapIt "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp -R Resources/web sprites "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
