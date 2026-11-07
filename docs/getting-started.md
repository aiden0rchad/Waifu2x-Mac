# Build and first run

Use these steps with the **native Swift checkout** of Waifu2x-Mac 2.8.0. Its root contains `Package.swift`. The 1.0.1 source preview has its own build instructions. [Builds and platform status](releases.md)

## 1. Set up Xcode

Use an Apple Silicon Mac and Xcode with the macOS 26 SDK or newer. Open Xcode once to finish its initial setup. If Xcode is in Applications, select it for the current terminal session:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun --sdk macosx --show-sdk-version
```

The app targets macOS 15 or later. **Apple ML** and **Apple VideoToolbox** interpolation require macOS 26 and supported hardware. The bundled Core ML engines are available without installing a separate runtime.

## 2. Build and open the app

From the native source root:

```sh
scripts/build-app.sh
open dist/Waifu2x-Mac.app
```

The script builds an arm64 app, copies the model resources, and signs the bundle for local use. It also accepts `debug` for development. [Packaging and signing](packaging.md)

## 3. Try a first file

Drop in a PNG or JPEG. Pick **Real-CUGAN** for line art or **Fast** for a quick resize. Continue to **Adjust** and compare the result at **2×**. Review the destination in **Export**, then run the job. [Illustrated walkthrough](walkthrough.md)

For the optional FLUX engine, use **Engine → AI → Download** or **Waifu2x-Mac → Settings → AI Engines**. [AI Restore requirements and setup](optional-engines.md)
