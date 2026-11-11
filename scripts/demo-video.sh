#!/bin/bash
# Renders a ~30 s promo video of Sysbar from live samples of this Mac.
# Usage: scripts/demo-video.sh [output.mp4]   (needs ffmpeg: brew install ffmpeg)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-sysbar-demo.mp4}
FRAMES=$(mktemp -d)
swift build -c release
.build/release/Sysbar --demo-frames "$FRAMES"
ffmpeg -y -loglevel error -framerate 4 -i "$FRAMES/f%05d.png" \
    -vf "scale=1920:1080:flags=lanczos,fps=30,format=yuv420p" \
    -c:v libx264 -preset slow -crf 20 -movflags +faststart "$OUT"
rm -rf "$FRAMES"
ls -lh "$OUT"
