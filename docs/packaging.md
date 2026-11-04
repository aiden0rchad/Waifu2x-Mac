# Packaging and signing

## What assembly does

`scripts/bundle-mac.sh` takes the compiled qmake app and a directory containing the extracted engine archives. It uses `macdeployqt` to add the Qt runtime, copies engine executables and model directories, builds the arm64 MetalFX helper, and creates wrappers for Homebrew media tools. It then signs the executables, frameworks, and app before copying and verifying the final bundle.

| Location | Contents |
| --- | --- |
| `build-mac/Waifu2xMacGUI.app` | qmake output used as the input to assembly |
| `dist/Waifu2x-Mac.app` | Final locally assembled app |
| `Contents/Frameworks` | Deployed Qt libraries and dependencies |
| `Contents/Resources/engines` | Engines, weights, helper wrappers, and engine-check fixtures |
| `/opt/homebrew/bin` | External FFmpeg, ImageMagick, and installed optional helpers |

## Verify the local bundle

From the repository root, run these commands after assembly.

```sh
app="dist/Waifu2x-Mac.app"
codesign --verify --deep --strict --verbose=2 "$app"
file "$app/Contents/MacOS/Waifu2xMacGUI"
plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist"
```

The main executable should show arm64. Run **Settings → Run engine check** after launching. The check exercises app-level tool discovery and complements signature verification.

## Signing and release files

The local assembly is ad-hoc signed for the build environment. The public preview distributes a versioned source tarball, a release manifest, and checksums. Qt libraries, model weights, and Homebrew binaries are acquired during local assembly. [Downloads and platform status](releases.md)

The source archive can be recreated from its pinned commit with `git archive --format=tar --prefix=Waifu2x-Mac-1.0.1/ v1.0.1 | gzip -n -9`. Use the published checksum to verify the actual uploaded bytes. For binary redistribution, review the upstream notices and the terms of each component and model. [License notices](https://github.com/aiden0rchad/Waifu2x-Mac/blob/main/NOTICE.md)
