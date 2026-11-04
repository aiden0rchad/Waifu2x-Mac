<div align="center">
  <img src="docs/public/assets/site-icon.png" width="72" alt="Waifu2x-Mac app icon">

# Waifu2x-Mac

**Give small images, GIFs, and videos a little more room.**

A desktop upscaler for Apple Silicon Macs.

[![Platform](https://img.shields.io/badge/macOS-Apple_Silicon-129BA3)](docs/getting-started.md)
[![Release v1.0.1](https://img.shields.io/badge/release-v1.0.1-7459DE)](https://github.com/aiden0rchad/Waifu2x-Mac/releases/tag/v1.0.1)
[![Docs](https://img.shields.io/badge/docs-setup_%26_walkthrough-169EAF)](https://aiden0rchad.github.io/Waifu2x-Mac/)
[![Documentation build](https://github.com/aiden0rchad/Waifu2x-Mac/actions/workflows/docs.yml/badge.svg?branch=main)](https://github.com/aiden0rchad/Waifu2x-Mac/actions/workflows/docs.yml)
[![License for Waifu2x-Mac contributions](https://img.shields.io/badge/license-AGPL--3.0-79DAC8)](LICENSE)
[![Buy Me a Coffee](https://img.shields.io/badge/Support-Buy%20Me%20a%20Coffee-FFDD00?style=flat&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/aiden0rchad)

**[Download v1.0.1 source preview](https://github.com/aiden0rchad/Waifu2x-Mac/releases/tag/v1.0.1)**

[Get started](docs/getting-started.md) · [Walkthrough](docs/walkthrough.md) · [Engines](docs/engines.md) · [Troubleshooting](docs/troubleshooting.md) · [Changelog](CHANGELOG.md)

</div>

Waifu2x-Mac gives you one place to upscale a tiny anime still or a folder of clips. Pick an engine, compare a preview, and save the results on your Mac.

## What it does

| If you're working with… | Start here |
| --- | --- |
| Anime, line art, or illustrations | Try **Real-CUGAN** at **2×**. Preview before turning up denoise. |
| Photos or live action | Compare **RealSR (Photos)** and **Real-ESRGAN (Photos)** on one frame. |
| A quick resize | Choose **MetalFX** for Apple's spatial upscaling. |
| Animated GIFs or videos | Pick an upscaler, then optionally turn on **Smoother motion** to generate intermediate frames with RIFE. |
| A wallpaper or a specific canvas | Switch from **Scale** to **Fit to…**, choose dimensions, and check the aspect-ratio option. |

Media processing runs on your Mac. A batch can use a shared output folder or put results beside the originals. Preview one item, save settings as a preset, and check the results gallery when the batch finishes.

## Get it running

The **v1.0.1 source preview** was tested on Apple Silicon with macOS 26 and Qt 6.11.1. Follow the build guide to compile and assemble the app with the upstream engine downloads and Homebrew helpers.

| Release file | Use it to |
| --- | --- |
| [Source archive](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v1.0.1/Waifu2x-Mac-1.0.1-source.tar.gz) | Build from the tagged source |
| [SHA256SUMS](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v1.0.1/SHA256SUMS) | Verify your downloads |
| [Build manifest](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v1.0.1/macos-arm64-release-manifest.json) | See build and test details |

[Release notes](https://github.com/aiden0rchad/Waifu2x-Mac/releases/tag/v1.0.1) · [Build and first run](docs/getting-started.md) · [Platform status](docs/releases.md)

1. Open the app and use **Settings → Run engine check**.
2. Drop in one PNG or JPEG and click **Next**.
3. Choose **MetalFX** and **2×** for a quick first run. Compare the preview with the original.
4. Pick an output folder in **Options**, then start the job from **Create**.

<details>
<summary><strong>See the app</strong></summary>

![Waifu2x-Mac showing the Add files screen and its four-step sidebar](docs/assets/add-files.png)

![Upscaler screen with engine choices and resolution controls](docs/assets/upscaler.png)

![Completed job with sample results in the gallery](docs/assets/results.png)

*The comparison and gallery use synthetic demo data. The walkthrough explains how to preview and inspect your own files.*

</details>

## Documentation

| Start here | Recipes and settings | Reference |
| --- | --- | --- |
| [New to upscaling?](docs/start-here.md) | [Images and wallpapers](docs/images.md) | [Builds and platform status](docs/releases.md) |
| [Build and first run](docs/getting-started.md) | [GIFs and video](docs/motion.md) | [Troubleshooting](docs/troubleshooting.md) |
| [Your first upscale](docs/walkthrough.md) | [Engines and models](docs/engines.md) | [FAQ and glossary](docs/faq.md) |
| [Privacy, storage, and updates](docs/privacy.md) | [Size, presets, and output](docs/settings.md) | [Architecture and source map](docs/architecture.md) |
| [Development and tests](docs/development.md) | [Advanced settings](docs/advanced.md) | [Packaging and signing](docs/packaging.md) |

The [docs site](https://aiden0rchad.github.io/Waifu2x-Mac/) has full-text search, a guide sidebar, and light and dark themes.

Found a bug? Include your macOS version, engine and model, the settings you used, and the smallest input that reproduces it. [Open an issue](https://github.com/aiden0rchad/Waifu2x-Mac/issues/new/choose) · [Contributing](.github/CONTRIBUTING.md)

## Licensing

Original Waifu2x-Mac contributions are licensed under AGPL 3.0. See the notices for inherited material and dependencies. [AGPL 3.0 license](LICENSE) · [License notices](NOTICE.md)
