# Troubleshooting and local data

## An engine check fails

Run **Settings → Run engine check**. An engine can fail because the app cannot find the executable, because a model folder is missing, or because the executable exits unsuccessfully. Confirm you launched `dist/Waifu2x-Mac.app` or its copy in Applications.

- **FFmpeg or ImageMagick** · Check that `/opt/homebrew/bin/ffmpeg`, `/opt/homebrew/bin/ffprobe`, and `/opt/homebrew/bin/magick` exist. The app calls those Homebrew installations through wrappers.
- **Real-CUGAN, Real-ESRGAN, RealSR, or RIFE** · Check the engine ZIP and extracted directory against the [build guide](getting-started.md). Keep each engine's model folders beside its executable, then assemble the bundle again.
- **MetalFX** · Check that you're on Apple Silicon. Run a small PNG through MetalFX at 2× to isolate the scaler from video encoding or interpolation.
- **Gifsicle** · Install it with `brew install gifsicle` and assemble again to add the wrapper. Retry with **Smaller GIFs** off if you only need to isolate an optimization failure.

## The build or app won't start

Check `uname -m` for `arm64` and confirm you're using the Qt 6 qmake from `/opt/homebrew/bin/qmake6`. If the build directory was configured with a different Qt install, configure in a new build directory. Verify the local app signature.

```sh
codesign --verify --deep --strict dist/Waifu2x-Mac.app
```

If verification fails, assemble again from a fresh GUI build. The packaging script signs the finished bundle after copying its resources.

## Preview works but the job is slow or fails

The preview processes a small crop. The full job processes entire images and, for video, many decoded frames. Try a smaller target, disable smoother motion, and check free disk space on the output volume. If an AI engine runs out of GPU memory, try a smaller tile size in **Advanced settings → Engine**. Smaller tiles can take longer.

For a failed video or GIF, try a short known-good MP4 or GIF. Check that the chosen output folder is writable and that FFmpeg passes the engine check. If the app shows a partial result, inspect the individual results before repeating the batch.

## Where settings and media live

The app stores settings and runtime data under `~/Library/Application Support/Waifu2xMacGUI`. Qt preferences also use the app's established macOS preferences identity. First launch can copy data from earlier Mac builds. The selected output folder or source folder receives the files you create.

Use **Settings → Reset to defaults** to reset settings, then restart. Back up the app data directory first if you want to keep local history and preferences. Previews and batch media processing run on the Mac. Homebrew installs and engine or model downloads use the network.

## Report a reproducible problem

Include macOS version, chip, Waifu2x-Mac version, the engine check result, file type and dimensions, and your steps. Share a small test file you have permission to post and redact personal paths from logs. [Issue form](https://github.com/aiden0rchad/Waifu2x-Mac/issues/new/choose)

## Match the symptom to the next check

| Symptom | Next check |
| --- | --- |
| An optional photo model appears but fails | Check the model pair beside the Real-ESRGAN executable. Test with a stock model or RealSR to isolate the missing weights. |
| Preview works and the full image fails | Try Auto or a smaller tile, fewer parallel files, and a smaller scale or target. The preview is a crop. |
| Output dimensions differ from the target | Check **Fit inside (keep aspect)** and whether the source is already larger than the target. [Size and presets](settings.md) |
| A video fails near the end | Look at the detailed log for the encoder error. Retry a short clip with H.264 and remove extra FFmpeg arguments while isolating the problem. |
| GIF or video motion looks distorted | Compare the same clip with **Smoother motion** disabled. Check cuts and overlapping moving objects before increasing the multiplier. |
| An output is missing from the expected folder | Check per-file status in **Create**, then use **Reveal** on a successful result to verify the exact path. |
