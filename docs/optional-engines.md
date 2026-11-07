# Optional AI Restore

**FLUX.2 klein Restore** is an optional generative engine for still images and animated GIFs. It can recover useful fine detail and may change colors, edges, or lettering. Check a preview before applying it to a batch.

## Install or remove

- Use an Apple Silicon Mac with macOS 15 or later and at least **16 GB** of memory.
- Allow about **8 GB** of free space for the first install. The 4-bit model is about 4.6 GB, the shared runtime about 1.3 GB, and installation needs 2 GB of working space.
- In **Engine → AI**, click **Download**, wait for **Installed**, and select the card. You can also manage the download in **Waifu2x-Mac → Settings → AI Engines**.
- **Pause** keeps the partial download so you can resume later, including after restarting the app. **Cancel** discards the partial model download.
- To reclaim disk space, use **Settings → AI Engines → Remove…**. The shared runtime is removed when the last optional engine is removed.

Downloads live at `~/Library/Application Support/Waifu2x-Mac/Engines/`. Bundled engines work offline from the first launch. FLUX needs internet access during installation and runs locally afterward.

## Preview and tune

1. Select an image or GIF in **Adjust**. The first comparison uses the base engine, so you can check the size while deciding whether to run AI.
2. Click **Preview AI** below the canvas or press **⌘R**. On a GIF the preview restores the first frame. The same generated preview is used for **Fit** and **Actual Pixels**, so changing the crop alone does not run AI again.
3. Drag the divider to inspect text, faces, and edges. If the edits are too strong, reduce **Strength** to mix in more of the base upscale.
4. Export once you’re happy with the preview. A mixed batch uses the selected video engine on clips.

| Control | When to use it |
| --- | --- |
| **Character Details** | Describe a detail to preserve, such as eye color or hair color, in up to 200 characters. |
| **References** | Add up to four images for the current batch. Crop to the relevant face or detail. References can introduce content from another image, so inspect the result. |
| **Keep Original Colours** | Match the restored colors more closely to the original. |
| **Protect Text** | Blend base pixels back into dark text and thick strokes that become hollow. |
| **More → Base Engine** | Auto uses Real-CUGAN for illustrations or RealSR for photo-oriented choices. Pick a base engine explicitly to control the finish. |
| **More → Safety Check** | If the output changes too much of the structure, retry without references, then try a different seed. If neither passes, use the base upscale. |
| **More → Seed / Prompt** | Set a seed or edit the restoration prompt. **Reset Prompt** returns to the default. |

AI restoration runs at up to 1024 pixels per side, then the base engine finishes the requested size. Reference images and crops are cleared by **File → Clear Batch**. The preview and export status can report when references were skipped or the base result was used.

## Animated GIFs

FLUX restores each unique frame and reuses its result for matching frames. The engine card gives about 25 seconds per image as a guide. Frame count, references, safety retries, and hardware affect the time, so start with a short GIF. The exported GIF retains transparency and its timing and loop behavior, subject to your export settings.

## Downloads and licenses

| Component | Source and terms |
| --- | --- |
| FLUX.2 klein 4B | Black Forest Labs, [Apache-2.0 model](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B). |
| 4-bit checkpoint | [Community conversion at the pinned revision](https://huggingface.co/Norton0924/FLUX.2-klein-4B-4bit/tree/7da9a04a7dd7312d9a8bc5848d155c74963815ee). |
| Runtime installer | [uv 0.9.8 arm64 release](https://github.com/astral-sh/uv/releases/tag/0.9.8). Waifu2x-Mac checks the archive SHA-256 before using it. |
| Local inference runtime | [mflux 0.24.0](https://pypi.org/project/mflux/0.24.0/) in a managed Python 3.12 environment. Installed packages retain their own licenses. |
