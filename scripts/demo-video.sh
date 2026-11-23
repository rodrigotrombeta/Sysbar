#!/bin/bash
# Renders a ~44 s promo video of Sysbar from live samples of this Mac, with
# an original soundtrack (scripts/demo-music.swift).
# Usage: scripts/demo-video.sh [output.mp4]   (needs ffmpeg: brew install ffmpeg)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-sysbar-demo.mp4}
FRAMES=$(mktemp -d)
swift build -c release
.build/release/Sysbar --demo-frames "$FRAMES"
swiftc -O scripts/demo-music.swift -o "$FRAMES/demo-music"
"$FRAMES/demo-music" "$FRAMES/music.wav" 44 14
ffmpeg -y -loglevel error -framerate 12 -i "$FRAMES/f%05d.png" -i "$FRAMES/music.wav" \
    -vf "scale=1920:1080:flags=lanczos,format=yuv420p" -r 30 \
    -c:v libx264 -preset slow -crf 20 -c:a aac -b:a 160k -shortest -movflags +faststart "$OUT"
rm -rf "$FRAMES"
ls -lh "$OUT"
