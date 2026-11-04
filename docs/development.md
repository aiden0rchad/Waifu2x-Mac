# Development

Follow the [local build guide](getting-started.md) for Qt modules, engine assets, and assembly. The macOS UI is built with Qt Widgets. The pipeline launches helper processes for upscaling, frame interpolation, and media conversion.

| Path | Role |
| --- | --- |
| `src/Waifu2xMacGUI.pro` | qmake build, app version, and Qt modules |
| `src/wizard.cpp` and `src/wizard_preview.cpp` | Four-step interface, settings, and comparison preview |
| `src/platform.h` and `src/main.cpp` | Platform paths, migration, startup, and test entry points |
| `src/image.cpp`, `src/gif.cpp`, and `src/video.cpp` | Media processing paths |
| `src/metalfx-upscale/` | Objective-C++ MetalFX spatial upscaler |
| `scripts/bundle-mac.sh` | Qt deployment, engine layout, wrappers, and ad-hoc signing |
| `scripts/branding/` | App artwork and icon generation |

## Run the smoke checks

Run these checks from the repository root after bundling.

```sh
(
  set -e
  app="$PWD/dist/Waifu2x-Mac.app"
  data="$(mktemp -d)"
  trap 'rm -rf "$data"' EXIT
  codesign --verify --deep --strict "$app"
  for check in migration quit preview resume; do
    W2X_DATA_DIR="$data/$check" W2X_SELFTEST="$check" \
      "$app/Contents/MacOS/Waifu2xMacGUI"
  done
)
```

For a UI or pipeline change, also run one small image at 2×, verify its output dimensions, and test any affected animation or video path with a short clip.

## Capture the walkthrough UI

```sh
screens="$(mktemp -d /tmp/waifu2x-mac-docs.XXXXXX)"
W2X_DATA_DIR="$screens/test-data" \
W2X_SNAPSHOT_DIR="$screens" W2X_SCHEME=light \
  dist/Waifu2x-Mac.app/Contents/MacOS/Waifu2xMacGUI
```

The snapshot mode loads synthetic inputs and writes images of the actual UI. Use a fresh test directory, keep only the relevant PNGs under `docs/assets`, and identify sample screens as such in docs.

## Documentation site

The site uses VitePress with a local search index. Markdown files in this directory are also readable on GitHub. With Node.js 22.19 or later, run the docs locally from the repository root.

```sh
npm --prefix docs ci
npm --prefix docs run dev
```

Run `npm --prefix docs run build` before pushing. The build checks internal Markdown links. Add new guides to the appropriate sidebar group in `docs/.vitepress/config.mts`. The Documentation workflow builds pull requests and deploys changes from the default branch.
