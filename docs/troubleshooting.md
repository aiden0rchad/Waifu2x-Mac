# Troubleshooting

## The app won't build or open

- In the **native** checkout, verify that `Package.swift` is in the project root and that `xcrun --sdk macosx --show-sdk-version` reports 26 or later.
- Use `scripts/build-app.sh` to assemble the app. The output is `dist/Waifu2x-Mac.app`. The script copies the model resources and verifies its local signature.
- Confirm you’re running on Apple Silicon and macOS 15 or newer. Use the instructions for your build if you downloaded a historical release. [Build and first run](getting-started.md) · [Builds and platform status](releases.md)

## A model or control is unavailable

| Symptom | What to check |
| --- | --- |
| Apple ML or Apple VideoToolbox is unavailable | Check **Settings → General**. Use **Fast** for resize or **RIFE 4.6** for eligible motion sources. |
| FLUX shows a missing runtime or incomplete installation | Open **Settings → AI Engines**. Resume a paused download or download again. Check available storage and the 16 GB memory requirement. |
| **Preview AI** is missing | Select the installed FLUX engine and an image or GIF in **Adjust**. Videos use the video engine. |
| **Smoother Motion** is unavailable with video | Choose a per-frame video engine. NanoVSR preserves source cadence. |
| **Actual Pixels** is unavailable | Choose a file in **Adjust**. For a video using NanoVSR, use the temporal preview. |

## Preview works but export fails or runs slowly

- Check the target and model limits. For NanoVSR, try a shorter low-resolution clip, or use SAFMN++ Light for a larger supported source.
- Try a smaller target or the **Fast** engine if a neural intermediate exceeds the size limit. High-resolution 4× output, motion interpolation, and optional AI take longer.
- Check that **Save To** points to a writable folder with room for the output. Open the failed row’s context menu for **Copy Error** if present.
- **Stop** keeps files that finished and discards the unfinished result. Check the failed or stopped rows before selecting **Export Remaining**.

[Engine limits](engines.md) · [GIF and video limits](motion.md)

## Report a reproducible problem

Include the app version, macOS version, Apple chip, source format and dimensions, engine, size, and the relevant export settings. Share the exact error and a small sample you have permission to distribute. [Open an issue](https://github.com/aiden0rchad/Waifu2x-Mac/issues/new/choose)
