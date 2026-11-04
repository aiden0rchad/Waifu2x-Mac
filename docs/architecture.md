# Architecture

Waifu2x-Mac uses Qt 6 Widgets for its macOS wizard. It reuses the upstream media queues and pipeline and launches upscaling and conversion tools as local subprocesses.

## How a job moves through the app

1. **Intake** categorizes files into image, GIF, and video tables. The wizard builds its cards and metadata from those queues.
2. **Configuration** maps the selected engine, model, target size, and output settings to the underlying pipeline controls.
3. **Preview** reads a still or extracts a sample frame. It scales a center crop using the chosen engine and planned passes, then displays the original and processed crop.
4. **Processing** runs the selected engine. Animation and video paths handle frame extraction, optional RIFE interpolation, and reconstruction. FFmpeg handles video encoding and container operations.
5. **Results** tracks per-file status and displays output paths and thumbnails. A completed batch can contain failures, so inspect the individual cards.

## Source map

| Area | Files |
| --- | --- |
| Startup, storage, and migration | `src/main.cpp`, `src/platform.h`, `src/settings.cpp` |
| Wizard and before/after UI | `src/wizard.cpp`, `src/wizard_preview.cpp` |
| File queue and media types | `src/files.cpp`, `src/table.cpp` |
| Image, GIF, APNG, and video jobs | `src/image.cpp`, `src/gif.cpp`, `src/AnimatedPNG.cpp`, `src/video.cpp` |
| Engine dispatch and interpolation | `src/waifu2x_ncnn_vulkan.cpp`, `src/realsr_ncnn_vulkan.cpp`, `src/Frame_Interpolation.cpp` |
| MetalFX helper | `src/metalfx-upscale/main.mm` |
| Local app assembly | `scripts/bundle-mac.sh` |

## Where the app finds engines

The assembled app keeps helpers and model folders under `Contents/Resources/engines`. The bundle script creates relative symlinks in `Contents/MacOS` for the existing engine lookup paths. Some media helpers are wrappers that invoke the Homebrew installations. Re-run assembly when the engine set changes. [Packaging and signing](packaging.md)

Use the [development guide](development.md) for tests and the [privacy guide](privacy.md) for user data.
