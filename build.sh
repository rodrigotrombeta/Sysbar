#!/bin/bash
# Builds Sysbar.app into ./build. Usage:
#   ./build.sh            # build only
#   ./build.sh install    # build and copy to /Applications, then launch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Sysbar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Sysbar "$APP/Contents/MacOS/Sysbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Apache-2.0 §4(a): ship the license with every distributed copy.
cp LICENSE "$APP/Contents/Resources/LICENSE"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Sysbar 2>/dev/null || true
    rm -rf /Applications/Sysbar.app
    cp -R "$APP" /Applications/
    touch /Applications/Sysbar.app   # nudge Finder/Dock to refresh the icon
    open /Applications/Sysbar.app
    echo "Installed to /Applications/Sysbar.app"
fi
