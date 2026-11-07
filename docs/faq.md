# FAQ and glossary

## What do I need to run it?

The native app targets macOS 15 or later on Apple Silicon. Building it requires Xcode with the macOS 26 SDK or newer. Apple’s optional super resolution and frame interpolation also require a compatible Mac and macOS 26 or later. [Build instructions](getting-started.md) · [Platform status](releases.md)

## Does it upload my files?

Processing takes place on your Mac. The optional AI engine uses internet access to download its runtime and weights. Once installed, FLUX processes files locally. [Privacy and storage](privacy.md)

## Why does my 4K result have one smaller dimension?

With **Keep Aspect Ratio** on, **4K** is a 3840 × 2160 bounding box. Both dimensions fit within it while preserving the source shape. **Adjust** shows the computed size. [Size settings](settings.md)

## Why does the preview finish faster than the export?

Fit can render a smaller sample. Actual Pixels processes a crop at export scale. Video and GIF previews show a still sample, while export processes the full animation and encodes it. If you choose FLUX, **Preview AI** generates the selected sample on demand. [Walkthrough](walkthrough.md)

## Can it preserve transparency and audio?

PNG preserves image alpha, and GIF export keeps frame transparency. JPEG fills transparent areas with white. Video can retain the primary audio track as AAC in the exported MP4. [Output choices](settings.md#output-and-filenames)

## Glossary

| Term | Meaning in the app |
| --- | --- |
| **Upscaling** | Making an image or frame larger. A 2× scale doubles width and height. |
| **Denoise** | Reducing visual noise or compression artifacts. Higher settings can also soften lines. |
| **Spatial engine** | An upscaler that processes one frame at a time. |
| **Temporal engine** | An upscaler that uses neighboring frames to recover detail. |
| **Interpolation** | Generating frames between source frames to smooth motion. |
| **Actual Pixels** | Inspecting a crop at the selected output scale. |
| **Core ML / MLX** | Apple frameworks used by the bundled model pipeline and the optional FLUX runtime, respectively. |
