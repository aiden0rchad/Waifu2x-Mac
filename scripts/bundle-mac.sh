#!/bin/bash
# Assemble dist/Waifu2x-Mac.app on macOS.
#   usage: scripts/bundle-mac.sh <path/to/Waifu2xMacGUI.app> <engines-dir>
# <engines-dir> holds the unzipped macOS releases, one subfolder each:
#   waifu2x/ realsr/ srmd/ rife/   (any depth; the *-ncnn-vulkan binary and models-* dirs are found automatically)
# ffmpeg, ffprobe and ImageMagick come from Homebrew (brew install ffmpeg imagemagick).
# Optional extra Real-ESRGAN models (anime and photo models): run
#   scripts/fetch-extra-models.sh <engines-dir>/realesrgan/models
# before bundling; the app lists them in the Real-ESRGAN model dropdown.
#
# Engines, wrappers and data live in Contents/Resources/engines and are symlinked into
# Contents/MacOS, because the app looks for them next to its executable while codesign
# refuses real subfolders with dotted names (rife-v2.3) and unsigned files in Contents/MacOS.
set -euo pipefail

APP=${1:?usage: bundle-mac.sh <app> <engines-dir>}
ENGINES=${2:?usage: bundle-mac.sh <app> <engines-dir>}
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
ENGINES="$(cd "$ENGINES" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src"
FINAL_APP="$ROOT/dist/Waifu2x-Mac.app"
DEST="$APP/Contents/MacOS"
RES="$APP/Contents/Resources/engines"
BREW=/opt/homebrew/bin

[ -d "$DEST" ] || { echo "not an app bundle: $APP" >&2; exit 1; }
[ "$APP" != "$FINAL_APP" ] || { echo "use the raw build bundle as input" >&2; exit 1; }

echo "==> macdeployqt"
"$(dirname "${QMAKE:-/opt/homebrew/bin/qmake6}")/macdeployqt" "$APP"

echo "==> engines"
mkdir -p "$RES"
for e in waifu2x realsr srmd rife realcugan realesrgan; do
    bin=$(find "$ENGINES/$e" -type f -name "$e-ncnn-vulkan" | head -1)
    [ -n "$bin" ] || { echo "missing $e-ncnn-vulkan under $ENGINES/$e" >&2; exit 1; }
    out="$RES/$e-ncnn-vulkan"
    rm -rf "$out"; mkdir -p "$out"
    # program plus its model folders only (the Real-ESRGAN package also ships demo media)
    cp "$bin" "$out/$e-ncnn-vulkan_waifu2xEX"
    for m in "$(dirname "$bin")"/models* "$(dirname "$bin")"/rife*; do
        [ -d "$m" ] && cp -R "$m" "$out"/
    done
    chmod +x "$out/$e-ncnn-vulkan_waifu2xEX"
done

echo "==> MetalFX engine"
rm -rf "$RES/metalfx"; mkdir -p "$RES/metalfx"
"$SRC/metalfx-upscale/build.sh" "$RES/metalfx/metalfx-upscale_waifu2xEX"

echo "==> helper wrappers (Homebrew)"
wrap() { # name target [prefix-args]
    printf '#!/bin/sh\nexec %s %s"$@"\n' "$2" "${3:+$3 }" > "$RES/$1_waifu2xEX"
    chmod +x "$RES/$1_waifu2xEX"
}
wrap ffmpeg   "$BREW/ffmpeg"
wrap ffprobe  "$BREW/ffprobe"
wrap convert  "$BREW/magick" convert
wrap identify "$BREW/magick" identify
for t in gifsicle apngasm apngdis; do
    if [ -x "$BREW/$t" ]; then wrap "$t" "$BREW/$t"; else echo "   (skipping $t: brew install $t)"; fi
done
rm -rf "$RES/SoX"
[ -x "$BREW/sox" ] && { mkdir -p "$RES/SoX"; printf '#!/bin/sh\nexec %s "$@"\n' "$BREW/sox" > "$RES/SoX/sox_waifu2xEX"; chmod +x "$RES/SoX/sox_waifu2xEX"; }

echo "==> resources"
cp "$SRC"/language_*.qm "$RES"/ 2>/dev/null || true
[ -f "$SRC/NFSound_Waifu2xEX.mp3" ] && cp "$SRC/NFSound_Waifu2xEX.mp3" "$RES"/
rm -rf "$RES/Compatibility_Test"; T="$RES/Compatibility_Test"; mkdir -p "$T"
"$BREW/magick" rose: -resize 200x200 "$T/Compatibility_Test.jpg"
"$BREW/ffmpeg" -v error -y -f lavfi -i testsrc=duration=2:size=320x240:rate=24 -f lavfi -i sine=duration=2 \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$T/CompatibilityTest_Video.mp4"
"$BREW/ffmpeg" -v error -y -f lavfi -i sine=duration=2 "$T/CompatibilityTest_Video_audio.wav"

# Expose everything next to the executable (where the app looks) as symlinks.
for p in "$RES"/*; do
    n=$(basename "$p")
    rm -rf "$DEST/$n"
    ln -s "../Resources/engines/$n" "$DEST/$n"
done

# Sign inside-out after the last modification. An invalid signature makes macOS kill the
# app on launch (SIGKILL, "Code Signature Invalid"), so the final verify is fatal.
echo "==> codesign (ad-hoc)"
sign() { codesign --force -s - "$@"; }
while IFS= read -r f; do
    if file "$f" | grep -q 'Mach-O'; then sign "$f"; fi
done < <(find "$RES" "$APP/Contents/PlugIns" -type f)
for fw in "$APP"/Contents/Frameworks/*.framework; do sign "$fw"; done
sign "$APP"
codesign --verify --strict "$APP"

echo "==> distributable bundle"
mkdir -p "$ROOT/dist"
rm -rf "$FINAL_APP"
ditto "$APP" "$FINAL_APP"
sign "$FINAL_APP"
codesign --verify --strict "$FINAL_APP"
echo "done: $FINAL_APP"
