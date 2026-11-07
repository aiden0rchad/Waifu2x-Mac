# Privacy, storage, and updates

## Local processing

The bundled engines read and process media on your Mac. They need no account or network access. If you choose **Download** for FLUX.2 klein Restore, the app fetches the optional runtime and model from their distribution servers. After installation the AI runtime runs locally with model-hub and Transformers offline modes enabled.

## What the app keeps

| Data | Where it lives |
| --- | --- |
| Original files | At the paths you selected. |
| Completed exports | Beside originals or in the folder you choose in **Export**. |
| Preferences, saved presets, and recent export paths | Local macOS preferences. **Settings → General → Clear Recent Exports** clears the list. |
| Reference images and preview caches | In the current session. **File → Clear Batch** clears the batch and its references. |
| Optional model and runtime | `~/Library/Application Support/Waifu2x-Mac/Engines/`. Manage it in **Settings → AI Engines**. |

Closing a window can leave the app running. Use **Waifu2x-Mac → Quit Waifu2x-Mac** before replacing the app bundle.

## Update your local build

Build from the updated native source checkout, quit the old app, then replace or reopen the bundle. The model store and macOS preferences are separate from the app, so they can carry over between native builds. The historical Qt preview has separate settings. [Build and first run](getting-started.md) · [Builds and platform status](releases.md)

## Share diagnostic information

When reporting a bug, crop screenshots and remove private paths and prompts from errors. Share input media only when you have permission to distribute it. [Troubleshooting](troubleshooting.md#report-a-reproducible-problem)
