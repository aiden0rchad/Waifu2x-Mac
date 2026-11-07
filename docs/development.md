# Development

Use the native Swift checkout on Apple Silicon and select Xcode with the macOS 26 SDK. The app builds with Swift Package Manager. [Build and first run](getting-started.md) · [Source map](architecture.md)

## Build and test

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
scripts/build-app.sh debug
open dist/Waifu2x-Mac.app
```

The normal suite exercises dimensions and file naming, model rendering and tile blending, image transparency, GIF timing and loops, video orientation and audio, motion interpolation, and optional engine installation with local fixtures. The app’s standard build and test commands use the checked-in Core ML packages. [Rebuilding model packages](models.md)

After installing FLUX in the app, use `W2X_FLUX_TEST=1 swift test` to include the two tests that run against the installed model and runtime.

For a UI change, try one PNG or JPEG, one animated GIF, and one short video. Check the **Files** card metadata, engine selection, Fit and Actual Pixels, and the **Export** results. If the change touches AI Restore, verify both the base preview and an explicitly generated **Preview AI**.

## Capture the walkthrough UI

Use media that can be shared publicly. The screenshots in `docs/assets/` use synthetic landscapes. Capture the app window without the desktop or personal folders. For output screenshots, complete a real export on the demo batch so the status and dimensions match the example.

## Documentation site

The GitHub Pages site uses VitePress with the same filenames as the Markdown guides. Use Node.js 22.19 or newer:

```sh
npm --prefix docs ci
npm --prefix docs run dev
npm --prefix docs run build
```

The build validates page links. The Documentation workflow checks changes on pull requests and deploys from the default branch. Keep existing guide URLs stable so old bookmarks continue to work.
