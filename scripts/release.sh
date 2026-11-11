#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Sysbar.app and packages it as
# dist/Sysbar-<version>.dmg (drag-to-Applications) and dist/Sysbar-<version>.zip.
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DIST=dist
APP="$DIST/Sysbar.app"

echo "==> Building Sysbar $VERSION (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Sysbar"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sysbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature (no Developer ID): users confirm the first launch once.
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"
lipo -info "$APP/Contents/MacOS/Sysbar"

echo "==> Creating DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Sysbar $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
    "$DIST/Sysbar-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"

echo "==> Creating ZIP"
ditto -c -k --keepParent "$APP" "$DIST/Sysbar-$VERSION.zip"

(cd "$DIST" && shasum -a 256 "Sysbar-$VERSION.dmg" "Sysbar-$VERSION.zip" > SHA256SUMS.txt)
ls -lh "$DIST"
