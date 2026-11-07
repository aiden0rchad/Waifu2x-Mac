# Builds and platform status

## Native 2.8.0

The Swift rebuild puts **Files**, **Engine**, **Adjust**, and **Export** in the toolbar. [What changed in 2.8.0](release-2.8.0.md) · [GitHub release](https://github.com/aiden0rchad/Waifu2x-Mac/releases/tag/v2.8.0)

| Download | What you get |
| --- | --- |
| [macOS arm64 app](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v2.8.0/Waifu2x-Mac-2.8.0-macos-arm64.zip) | Ad-hoc-signed app with bundled Core ML models |
| [Source archive](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v2.8.0/Waifu2x-Mac-2.8.0-source.zip) | Matching Swift source, model files, and documentation |
| [SHA256SUMS.txt](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v2.8.0/SHA256SUMS.txt) | SHA-256 checksums for both ZIP files |

Download both ZIPs and the checksum file into the same directory to verify them with `shasum -a 256 -c SHA256SUMS.txt`. [First launch and build instructions](getting-started.md)

| Component | Status |
| --- | --- |
| Main app | Apple Silicon, macOS 15 or later. Build with the macOS 26 SDK or newer. |
| Bundled engines | Core ML and macOS frameworks. Model files ship with the local app. |
| Apple ML and Apple VideoToolbox | macOS 26 or later on supported hardware. |
| FLUX.2 klein Restore | Optional download for Apple Silicon with at least 16 GB of memory. [Requirements](optional-engines.md#install-or-remove) |
| App ZIP | arm64, ad-hoc signed. Apple notarization is unavailable for this build. [Packaging](packaging.md) |

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
