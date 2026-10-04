#!/usr/bin/env bash
# Builds JSpice.app (Apple Silicon and Intel) into macos/build, and a zip of it for downloading.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/JSpice"

APP=build/JSpice.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JSpice"
cp Resources/Info.plist "$APP/Contents/Info.plist"

"$APP/Contents/MacOS/JSpice" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc signature: required to run on Apple Silicon; not notarized
codesign --force --deep --sign - "$APP"
(cd build && ditto -c -k --keepParent JSpice.app JSpice-macOS.zip)
echo "Built $APP"
