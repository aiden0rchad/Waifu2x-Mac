# Builds and platform status

## Native 2.8.0

These docs describe the Swift rebuild with the **Files**, **Engine**, **Adjust**, and **Export** toolbar. This build is available from the native source checkout. See [What changed in 2.8.0](release-2.8.0.md) and [Build and first run](getting-started.md).

| Component | Status |
| --- | --- |
| Main app | Apple Silicon, macOS 15 or later. Build with the macOS 26 SDK or newer. |
| Bundled engines | Core ML and macOS frameworks. Model files ship with the local app. |
| Apple ML and Apple VideoToolbox | macOS 26 or later on supported hardware. |
| FLUX.2 klein Restore | Optional download for Apple Silicon with at least 16 GB of memory. [Requirements](optional-engines.md#install-or-remove) |
| Local app bundle | arm64, ad-hoc signed for local use. [Packaging](packaging.md) |

The screenshots and a demo batch were verified on Apple Silicon with macOS 26.5.1. The 16 GB figure is the optional engine’s minimum; actual memory use and speed depend on the image or clip.

## Published 1.0.1 source preview

The previous Qt build is available from its tagged release. Follow the documentation at that tag if you’re compiling the source preview.

| Download | What you get |
| --- | --- |
| [Source archive](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v1.0.1/Waifu2x-Mac-1.0.1-source.tar.gz) | Tagged 1.0.1 source |
| [SHA256SUMS](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v1.0.1/SHA256SUMS) | Checksums for the release files |
| [Release manifest](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v1.0.1/macos-arm64-release-manifest.json) | Build environment and verification details |
| [Build guide at v1.0.1](https://github.com/aiden0rchad/Waifu2x-Mac/blob/v1.0.1/docs/getting-started.md) | Steps for the Qt preview |

[Published GitHub release](https://github.com/aiden0rchad/Waifu2x-Mac/releases/tag/v1.0.1)
