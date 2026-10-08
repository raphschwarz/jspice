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
# the MCP server that lets AI agents drive the app (or simulate on their own)
cp "$(dirname "$BIN")/jspice-mcp" "$APP/Contents/MacOS/jspice-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# the Audio Unit: an app extension, found by music apps once the app has been opened
APPEX="$APP/Contents/PlugIns/JSpiceAudioUnit.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$(dirname "$BIN")/JSpiceAudioUnit" "$APPEX/Contents/MacOS/JSpiceAudioUnit"
cp Resources/AudioUnit-Info.plist "$APPEX/Contents/Info.plist"

"$APP/Contents/MacOS/JSpice" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc signatures: required to run on Apple Silicon; not notarized. Inside out: the extension with its sandbox, the
# MCP server, then the app (a --deep signature would drop the extension's entitlements)
codesign --force --sign - --entitlements Resources/AudioUnit.entitlements "$APPEX"
codesign --force --sign - "$APP/Contents/MacOS/jspice-mcp"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
(cd build && ditto -c -k --keepParent JSpice.app JSpice-macOS.zip)
echo "Built $APP"
