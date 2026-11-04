# FAQ and glossary

## Can I install the preview without developer tools?

The current GitHub release is a source kit. Building it uses Apple's command-line tools, Qt, Homebrew helpers, and engine archives. See the [release status](releases.md) and [build guide](getting-started.md).

## Does it require an account or upload my files?

Media processing runs on the Mac. The documented dependency downloads use the network. GitHub CLI can ask you to authenticate for the download commands. See [Privacy, storage, and updates](privacy.md).

## Is there a native Intel build?

The preview was built and tested on Apple Silicon. The current packaging uses the Apple Silicon Homebrew prefix and builds the MetalFX helper for arm64. See [platform status](releases.md#platform-status).

## Why is 4K a different shape from my image?

4K here is a 3840 × 2160 bounding box. When preserving aspect ratio, a narrower input leaves room on one axis. Crop a copy to the desired aspect ratio beforehand if you need it to fill an exact canvas. [Target examples](settings.md#scale-versus-fit-to)

## Why does the preview finish faster than the job?

The comparison runs on a small crop. The job processes the full image or many frames, and can include decoding, audio processing, or encoding. [Video processing costs](motion.md#smoother-motion-and-cost)

## Glossary

| Term | Meaning |
| --- | --- |
| **Engine** | The program that runs the upscaling or frame interpolation. |
| **Model** | The learned weights an AI engine uses to decide what details to add or clean up. |
| **Denoise** | Reduces noise or compression artifacts. Higher levels can smooth away real details. |
| **Tile** | A piece of a larger frame processed separately to manage GPU memory. |
| **Interpolation** | Predicts intermediate frames to increase the apparent smoothness of motion. |
| **CRF** | A quality target for supported video encoders. Lower numbers generally mean more detail and larger files. |
| **Ad-hoc signature** | A local code signature without a Developer ID identity. The local bundle's signature can be verified with `codesign`. |
