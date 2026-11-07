# Packaging and signing

## Assemble the native app

From the root of the Swift checkout, use Xcode with the macOS 26 SDK and run:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-app.sh
```

The script builds arm64, adds the executable, icon, license, optional AI help, and bundled Core ML models, then signs and verifies `dist/Waifu2x-Mac.app`. The optional FLUX model and runtime are installed separately through the app.

## Verify the local bundle

```sh
app=dist/Waifu2x-Mac.app
codesign --verify --deep --strict "$app"
file "$app/Contents/MacOS/Waifu2xMac"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist"
open "$app"
```

The executable should report arm64 and the app version should match the version in the source build script. Check a small mixed batch before preparing an archive.

## Signing and release files

The local bundle uses an ad-hoc signature. For a distributed macOS app, Apple documents Developer ID signing and notarization. Keep the source archive, app archive, checksums, and release notes tied to the same version and source revision. Include the app license and the relevant model notices in distributed copies. [Apple’s notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

[Builds and platform status](releases.md) · [Bundled models and licenses](models.md)
