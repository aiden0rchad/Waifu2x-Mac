# Privacy, storage, and updates

## Local processing

Upscaling, interpolation, and media conversion run on your Mac through local helpers. Package managers, engine/model downloads, and links opened in a browser use the network. The media pipeline does not require a cloud inference account.

## Data and output

| Data | Location or behavior |
| --- | --- |
| Runtime settings and saved lists | `~/Library/Application Support/Waifu2xMacGUI` |
| Wizard preferences and recent results | Qt settings under the app's existing macOS preference identity |
| Final output | Beside the source or in the output folder selected in the wizard |
| Working data | The app can create frame and conversion caches while processing media. Keep space available near the job and avoid deleting caches during processing. |

The app can copy settings from earlier Mac builds on first launch. Close the app before backing up settings or replacing a local build. Keep the input and output folders separately if you want a complete backup of a job.

## Update your local build

1. Check the [release status](releases.md) and review the change notes.
2. Build the desired tag in a fresh directory and run the engine check.
3. Quit the existing app before replacing your copy in Applications. Use the new build to test a small job before running a batch.

## Share diagnostic information

Include the macOS version, chip, app version, engine/model, and the engine check results when reporting a bug. Redact paths that identify you, and use a public or synthetic input when possible. [Report an issue](https://github.com/aiden0rchad/Waifu2x-Mac/issues/new/choose)
