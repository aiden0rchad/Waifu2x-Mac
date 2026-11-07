# Waifu2x-Mac 2.8.0

The rebuilt app puts **Files**, **Engine**, **Adjust**, and **Export** in the window toolbar. Files uses a thumbnail grid, Engine groups model cards by media type, and Adjust gives the comparison canvas most of the window. The right inspector shows the output dimensions and processing controls.

- **Actual Pixels** opens a crop at the export scale. Switch samples from the filmstrip and use Fit to choose a different area.
- **Larger neural upscales** can chain passes when there is room. Real-CUGAN uses overlap blending to reduce visible tile boundaries and denoises once.
- **Optional FLUX.2 klein Restore** processes images and GIFs locally after installation. Preview AI lets you check reference images, color, text, and strength settings on one sample before export.
- **Export** shows destination, format options, and per-file results together. Batch progress includes an estimate during longer runs. The Dock and optional completion notifications report progress when the window is in the background.
- **Settings** remembers the last choices and includes a page for optional engine downloads.

The documentation demo exported two stills, an animated GIF, and a video using Real-CUGAN at 2×. It also generated a FLUX preview for one synthetic illustration.

[Walkthrough](walkthrough.md) · [Builds and platform status](releases.md)
