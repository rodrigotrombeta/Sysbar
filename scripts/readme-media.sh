#!/bin/bash
# Regenerates the README images and demo video in docs/ from live samples of
# this Mac (process names and the IP address are replaced with neutral ones).
# Usage: scripts/readme-media.sh   (needs ffmpeg: brew install ffmpeg)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=docs
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT/images"

swift build -c release
# Run from a throwaway bundle: the version shows in Settings and the settings
# changed while rendering stay out of your real preferences.
APP="$WORK/Sysbar.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Sysbar "$APP/Contents/MacOS/Sysbar"
sed 's|<string>local.sysbar.app</string>|<string>local.sysbar.readme-media</string>|' \
    Resources/Info.plist > "$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/Sysbar"

"$BIN" --screenshots "$OUT/images"
"$BIN" --demo-frames "$WORK/frames"
defaults delete local.sysbar.readme-media 2>/dev/null || true
rm -f ~/Library/Preferences/local.sysbar.readme-media.plist

# Stills from the demo: the panel with pinned details, and the icon styles.
sips -Z 1600 "$WORK/frames/f00060.png" --out "$OUT/images/hero.png" >/dev/null
sips -Z 1600 "$WORK/frames/f00030.png" --out "$OUT/images/icon-styles.png" >/dev/null

# Full-quality video (linked from the README) and an inline GIF.
ffmpeg -y -loglevel error -framerate 4 -i "$WORK/frames/f%05d.png" \
    -vf "scale=1280:-2:flags=lanczos,fps=30,format=yuv420p" \
    -c:v libx264 -preset slow -crf 22 -movflags +faststart "$OUT/sysbar-demo.mp4"
ffmpeg -y -loglevel error -framerate 4 -i "$WORK/frames/f%05d.png" \
    -vf "scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
    "$OUT/images/demo.gif"
ls -lh "$OUT" "$OUT/images"
