# Build and first run

Waifu2x-Mac 2.8.0 targets Apple Silicon and macOS 15 or later. [Builds and platform status](releases.md)

## Open the downloaded app

Download the macOS arm64 ZIP, extract it, then move **Waifu2x-Mac.app** to Applications. The release ZIP is ad-hoc signed and has no Apple notarization. macOS may block first launch under its Gatekeeper settings. [Download and checksums](releases.md#native-2-8-0) · [Apple’s guide to opening downloaded apps](https://support.apple.com/en-us/102445)

## Build from source

Use an Apple Silicon Mac and Xcode with the macOS 26 SDK or newer. Open Xcode once to finish its initial setup. If Xcode is in Applications, select it for the current terminal session:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun --sdk macosx --show-sdk-version
```

The app targets macOS 15 or later. **Apple ML** and **Apple VideoToolbox** interpolation require macOS 26 and supported hardware. The bundled Core ML engines are available without installing a separate runtime.

Clone the release tag, or extract the source archive and run the last two commands from the directory containing `Package.swift`:

```sh
git clone --branch v2.8.0 https://github.com/aiden0rchad/Waifu2x-Mac.git
cd Waifu2x-Mac
scripts/build-app.sh
open dist/Waifu2x-Mac.app
```

The script builds an arm64 app, copies the model resources, and signs the bundle for local use. It also accepts `debug` for development. [Packaging and signing](packaging.md)

## Try a first file

Drop in a PNG or JPEG. Pick **Real-CUGAN** for line art or **Fast** for a quick resize. Continue to **Adjust** and compare the result at **2×**. Review the destination in **Export**, then run the job. [Illustrated walkthrough](walkthrough.md)

For the optional FLUX engine, use **Engine → AI → Download** or **Waifu2x-Mac → Settings → AI Engines**. [AI Restore requirements and setup](optional-engines.md)
