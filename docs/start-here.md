# Start here

Waifu2x-Mac takes an image, GIF, or video and makes a larger copy. The app processes media locally, using the GPU for upscaling and helper tools for decoding and encoding.

## Choose a path

| Where you are | What to open |
| --- | --- |
| You have an Apple Silicon Mac and need the app | [Build and first run](getting-started.md) |
| You already have the app open | [Your first upscale](walkthrough.md) |
| You want to restore anime or a small photo | [Images and wallpapers](images.md) |
| You have a GIF or video | [GIFs and video](motion.md) |
| You're deciding whether to try the preview | [Builds and platform status](releases.md) |

## What to expect from your first run

Start with one PNG at **2×**, save into a separate folder, and use **MetalFX** for a quick check. A 240 × 150 input becomes 480 × 300. Once that works, switch to **Real-CUGAN** for drawn lines or **RealSR** for a photo, and compare a crop before processing the whole file.

Upscaling can clean up edges and compression artifacts. AI models can also introduce patterns, alter thin lines, or make faces look different. Keep the source and check the output at normal viewing size.

## The four screens

1. **Add files** queues your inputs.
2. **Upscaler** sets the engine, model, scale, and noise reduction.
3. **Options** sets output formats, destination, and motion controls where available.
4. **Create** starts the job and lists finished or failed results.

If a label is unfamiliar, see the [FAQ and glossary](faq.md). If an engine shows an error, start with [the engine check](troubleshooting.md).
