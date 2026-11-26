#!/usr/bin/env bash
# Builds JSpice.app (Apple Silicon and Intel) into macos/build, and a zip of it for downloading.
# The version comes from macos/VERSION, stamped into the app's and the Audio Unit's Info.plist with a build number and
# the commit (see "Version" below). `bundle.sh --print-version` prints what would be stamped, and builds nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

# --- Version ---
# VERSION: a semantic version (1.2.0, or 1.2.0-beta.1 for a pre-release). CFBundleShortVersionString takes its numbers
# alone, JSpiceVersion the whole of it (what the app, the Audio Unit and jspice-mcp report).
VERSION=$(tr -d ' \t\r\n' < VERSION)
if ! [[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "bundle.sh: macos/VERSION holds '$VERSION', not a semantic version such as 1.2.0" >&2
  exit 1
fi
SHORT_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
# the Audio Unit's component version, which hosts compare to know a plug-in changed: 0xMMMMmmpp
AU_VERSION=$(( 10#${BASH_REMATCH[1]} * 65536 + 10#${BASH_REMATCH[2]} * 256 + 10#${BASH_REMATCH[3]} ))
# CFBundleVersion, which must only ever increase: JSPICE_BUILD_NUMBER if set; else the number of commits, from a full
# clone (the release workflow fetches the whole history); else, in a shallow clone (CI's default) or outside git,
# 0.<minutes since 1970>, which increases too and sorts below every build numbered from the history
if [ -n "${JSPICE_BUILD_NUMBER:-}" ]; then
  BUILD="$JSPICE_BUILD_NUMBER"
elif [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = false ]; then
  BUILD=$(git rev-list --count HEAD)
else
  BUILD="0.$(( $(date -u +%s) / 60 ))"
fi
if ! [[ "$BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "bundle.sh: the build number '$BUILD' is not one to three numbers separated by dots" >&2
  exit 1
fi
COMMIT=$(git rev-parse --short=7 HEAD 2>/dev/null || true)
[ -n "$COMMIT" ] || { GITHUB_SHA=${GITHUB_SHA:-}; COMMIT=${GITHUB_SHA:0:7}; }
[ -n "$COMMIT" ] || COMMIT=unknown
if [ "${1:-}" = --print-version ]; then
  echo "VERSION=$VERSION"
  echo "SHORT_VERSION=$SHORT_VERSION"
  echo "BUILD=$BUILD"
  echo "COMMIT=$COMMIT"
  echo "AU_VERSION=$AU_VERSION"
  exit 0
fi

# sets the version keys of a copied Info.plist, then reads them back: a build with the wrong version is no build
stamp() {
  local plist="$1"; shift
  local buddy=/usr/libexec/PlistBuddy
  "$buddy" -c "Set :CFBundleShortVersionString $SHORT_VERSION" -c "Set :CFBundleVersion $BUILD" \
    -c "Set :JSpiceVersion $VERSION" -c "Set :JSpiceCommit $COMMIT" "$@" "$plist"
  [ "$("$buddy" -c 'Print :CFBundleShortVersionString' "$plist")" = "$SHORT_VERSION" ] \
    && [ "$("$buddy" -c 'Print :CFBundleVersion' "$plist")" = "$BUILD" ] \
    && [ "$("$buddy" -c 'Print :JSpiceVersion' "$plist")" = "$VERSION" ] \
    && [ "$("$buddy" -c 'Print :JSpiceCommit' "$plist")" = "$COMMIT" ] \
    || { echo "bundle.sh: stamping the version into $plist failed" >&2; exit 1; }
  plutil -lint "$plist" > /dev/null
}

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/JSpice"

APP=build/JSpice.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JSpice"
# the MCP server that lets AI agents drive the app (or simulate on their own)
cp "$(dirname "$BIN")/jspice-mcp" "$APP/Contents/MacOS/jspice-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
stamp "$APP/Contents/Info.plist"
# the Audio Unit: an app extension, found by music apps once the app has been opened
APPEX="$APP/Contents/PlugIns/JSpiceAudioUnit.appex"
mkdir -p "$APPEX/Contents/MacOS"
cp "$(dirname "$BIN")/JSpiceAudioUnit" "$APPEX/Contents/MacOS/JSpiceAudioUnit"
cp Resources/AudioUnit-Info.plist "$APPEX/Contents/Info.plist"
stamp "$APPEX/Contents/Info.plist" \
  -c "Set :NSExtension:NSExtensionAttributes:AudioComponents:0:version $AU_VERSION" \
  -c "Set :NSExtension:NSExtensionAttributes:AudioComponents:1:version $AU_VERSION"
[ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionAttributes:AudioComponents:1:version' "$APPEX/Contents/Info.plist")" = "$AU_VERSION" ] \
  || { echo "bundle.sh: stamping the Audio Unit's component version failed" >&2; exit 1; }
# the binaries read the stamped Info.plist: check they report this version
REPORTED=$("$APP/Contents/MacOS/jspice-mcp" --version)
[ "$REPORTED" = "jspice-mcp $VERSION (build $BUILD, commit $COMMIT)" ] \
  || { echo "bundle.sh: jspice-mcp --version says '$REPORTED', not version $VERSION (build $BUILD, commit $COMMIT)" >&2; exit 1; }

"$APP/Contents/MacOS/JSpice" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc signatures: required to run on Apple Silicon; not notarized. Inside out: the extension with its sandbox, the
# MCP server, then the app (a --deep signature would drop the extension's entitlements). The release workflow signs
# again with a Developer ID, when it has one.
codesign --force --sign - --entitlements Resources/AudioUnit.entitlements "$APPEX"
codesign --force --sign - "$APP/Contents/MacOS/jspice-mcp"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
(cd build && ditto -c -k --keepParent JSpice.app JSpice-macOS.zip)
echo "Built $APP, version $VERSION (build $BUILD, commit $COMMIT)"
