#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
configuration=${1:-release}
case "$configuration" in
    release|debug) ;;
    *) echo "Usage: $0 [release|debug]" >&2; exit 2 ;;
esac

build_flags=()
# Restricted CI can already supply an outer sandbox that prevents sandbox-exec nesting.
if [[ "${W2X_DISABLE_SWIFTPM_SANDBOX:-0}" == 1 ]]; then build_flags+=(--disable-sandbox); fi
swift build ${build_flags[@]+"${build_flags[@]}"} -c "$configuration" --arch arm64
binary="$(swift build ${build_flags[@]+"${build_flags[@]}"} -c "$configuration" --arch arm64 --show-bin-path)/Waifu2xMac"
mkdir -p dist
work="$(mktemp -d "$PWD/dist/.build.XXXXXX")"
destination="$PWD/dist/Waifu2x-Mac.app"
cleanup() {
    if [[ -e "$work/previous.app" && ! -e "$destination" ]]; then
        mv "$work/previous.app" "$destination" || return
    fi
    rm -r -- "$work"
}
trap cleanup EXIT
app="$work/Waifu2x-Mac.app"
contents="$app/Contents"
icons="$work/AppIcon.iconset"
mkdir -p "$contents/MacOS" "$contents/Resources" "$icons"
cp "$binary" "$contents/MacOS/Waifu2xMac"
cp LICENSE "$contents/Resources/LICENSE.txt"
# Optional runtimes and weights live in Application Support, never in this bundle.
cp docs/optional-engines.md "$contents/Resources/OptionalEngines.md"
cp -R Sources/UpscaleCore/Models "$contents/Resources/"

for size in 16 32 128 256 512; do
    retina=$((size * 2))
    sips -z "$size" "$size" branding/AppIcon.png --out "$icons/icon_${size}x${size}.png" > /dev/null
    sips -z "$retina" "$retina" branding/AppIcon.png --out "$icons/icon_${size}x${size}@2x.png" > /dev/null
done
if ! iconutil --convert icns "$icons" --output "$contents/Resources/AppIcon.icns"; then
    swift scripts/package-icon.swift "$icons" "$contents/Resources/AppIcon.icns"
fi

cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.waifu2xmac.native</string>
  <key>CFBundleName</key><string>Waifu2x-Mac</string>
  <key>CFBundleDisplayName</key><string>Waifu2x-Mac</string>
  <key>CFBundleExecutable</key><string>Waifu2xMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>2.8.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Media</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.image</string><string>public.movie</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [[ -e "$destination" ]]; then mv "$destination" "$work/previous.app"; fi
mv "$app" "$destination"
printf '%s\n' "$destination"
