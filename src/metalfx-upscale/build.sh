#!/bin/sh
# usage: build.sh [output-path]   (default: ./metalfx-upscale)
cd "$(dirname "$0")" && clang++ -std=c++17 -O2 -fobjc-arc -mmacosx-version-min=13.0 -arch arm64 main.mm \
    -framework Foundation -framework Metal -framework MetalFX -framework ImageIO -framework CoreGraphics \
    -framework UniformTypeIdentifiers -o "${1:-metalfx-upscale}"
