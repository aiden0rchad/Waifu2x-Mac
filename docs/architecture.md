# Architecture

Waifu2x-Mac is a SwiftUI app with a Swift package for processing. The app owns the queue, toolbar, inspector, and export state. **UpscaleCore** handles dimensions, preview generation, inference, and encoding.

## How a job moves through the app

1. **Files** adds supported local URLs to the queue. **Engine** records the image engine, optional AI engine, and video engine for the batch.
2. **Adjust** asks the core for a whole-image preview or a crop. For FLUX, the base preview is automatic and **Preview AI** runs the full restore on demand. Fit and Actual Pixels can share the generated preview.
3. **Export** snapshots the options and processes the queue. Core Image and Core ML render stills or frames. AVFoundation reads and writes video, and ImageIO writes PNG, JPEG, and GIF. Each successful result is moved from staging to a unique destination.
4. The app updates per-file progress and records completed output paths. The Dock badge and completion notifications are handled by the app layer.

## Source map

| Path | Responsibility |
| --- | --- |
| `Package.swift` | Swift package targets, platform minimum, and bundled model resources. |
| `Sources/Waifu2xMac/WorkspaceView.swift` | Toolbar, page routing, and inspector presentation. |
| `Sources/Waifu2xMac/FilesPage.swift`, `EnginePage.swift`, `CanvasView.swift`, `ExportPage.swift` | File cards, engine library, comparison canvas, and export controls. |
| `Sources/Waifu2xMac/Workspace.swift` | Batch selection, preview cache, settings, and export task. |
| `Sources/UpscaleCore/Upscale.swift`, `FrameRenderer.swift`, `NeuralScaler.swift` | Export dimensions, render routing, neural tiling, and output staging. |
| `Sources/UpscaleCore/VideoExport.swift`, `VideoNeuralScaler.swift`, `MotionInterpolation.swift` | Video decode and encode, temporal processing, and in-between frames. |
| `Sources/UpscaleCore/EngineInstaller.swift`, `DiffusionRestore.swift`, `RestoreGuard.swift` | Optional engine installation, local inference, and restoration checks. |
| `Sources/UpscaleCore/Models/` | Bundled Core ML resources and third-party notices. |
| `Tests/UpscaleCoreTests/` | Core tests, including model output, timing, and optional engine installation. |

## Where the app finds engines

Bundled models ship in the app resources. **Fast** uses MetalFX on supported inputs, and the Apple ML and Apple motion choices use system frameworks. FLUX runs through a separately installed mflux environment. Its files are stored under `~/Library/Application Support/Waifu2x-Mac/Engines/`.

[Engine catalog](engines.md) · [Checkpoint provenance](models.md) · [Development](development.md)
