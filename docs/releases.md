# Builds and platform status

## v1.0.1 source preview

| Download | What you get |
| --- | --- |
| [Source archive](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v1.0.1/Waifu2x-Mac-1.0.1-source.tar.gz) | Tagged project files in a versioned tarball |
| [SHA256SUMS](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v1.0.1/SHA256SUMS) | Checksums for the archive and manifest |
| [Release manifest](https://github.com/aiden0rchad/Waifu2x-Mac/releases/download/v1.0.1/macos-arm64-release-manifest.json) | Commit, build environment, engine versions, and verification results |

Download the archive and checksum file into the same directory, then verify the archive before extracting it. The manifest is covered by the checksum list as well if you download it.

```sh
shasum -a 256 Waifu2x-Mac-1.0.1-source.tar.gz
```

Compare the printed hash with the archive's line in `SHA256SUMS`. With both assets and the checksum file present, you can use `shasum -a 256 -c SHA256SUMS`.

Follow [Build and first run](getting-started.md) to compile and assemble the app. The release is pinned to the v1.0.1 source commit. These live docs can receive clarifications between app releases. [Release notes](https://github.com/aiden0rchad/Waifu2x-Mac/releases/tag/v1.0.1) · [Changelog](https://github.com/aiden0rchad/Waifu2x-Mac/blob/main/CHANGELOG.md)

## Platform status

| Platform or component | Preview status |
| --- | --- |
| Apple Silicon on macOS 26 | Compiled, assembled, and tested on an M3 Max running macOS 26.5.1 |
| Older macOS versions | Outside the tested Homebrew build configuration |
| Intel Mac | Outside the tested packaging configuration |
| Windows and Linux | Outside the supported platforms for Waifu2x-Mac. |
| Local app signature | The bundle script ad-hoc signs the app for local use |
| Public package | Source archive. The upstream file headers and repository license specify different terms for inherited material. [License notices](https://github.com/aiden0rchad/Waifu2x-Mac/blob/main/NOTICE.md) |

## Validation scope

The archive was extracted into a fresh directory and used to compile and assemble the application. Signature verification and migration, quit, preview-plan, and interrupted-cache tests passed. Separate local smoke checks exercised MetalFX, Real-CUGAN, Real-ESRGAN, RealSR, RIFE, and FFmpeg on small synthetic inputs. Performance and compatibility can vary with the Mac, model, and source media.

See [Packaging and signing](packaging.md) for what the local app contains and [Privacy, storage, and updates](privacy.md#update-your-local-build) for replacing an existing build.
