#!/bin/bash
# Update the app and docs icons from AppIcon-1024.png. Requires iconutil and ImageMagick.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
WORK="$(mktemp -d)"
trap 'rm -r -- "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for p in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $p
    magick AppIcon-1024.png -filter Lanczos -resize "${1}x${1}" "$ICONSET/$2.png"
done
iconutil --convert icns "$ICONSET" --output "$ROOT/src/icon/icon.icns"
magick AppIcon-1024.png -define icon:auto-resize=256,48,32,16 "$ROOT/src/icon/icon.ico"
magick AppIcon-1024.png -resize 512x512 "$ROOT/src/icon/icon_main.png"
magick AppIcon-1024.png -filter Lanczos -resize 256x256 "$ROOT/src/icons/wizard/appicon.png"
cp "$ROOT/src/icons/wizard/appicon.png" "$ROOT/docs/public/assets/site-icon.png"
