# Size, presets, and output

## Output size in Adjust

Use **2×**, **3×**, or **4×** to multiply both dimensions. **More** opens fit targets such as **1080p**, **1440p**, **4K**, **Portrait**, and **Custom**.

With **Keep Aspect Ratio** on, a 640 × 400 image fits inside the 1080p target at 1728 × 1080. Turn it off to stretch to 1920 × 1080. Check the large dimensions above the scale controls for the selected file. The preview’s **Fit** and **Actual Pixels** buttons control viewing only.

Still images and GIF frames can export up to 16,384 px per side and 50 megapixels. Video can export up to 4,096 px per side and rounds to even dimensions. The intermediate size required by an engine can have a smaller limit. [Engine limits](engines.md)

## Presets

Open **Presets** on the **Engine** page. Start from a shortcut such as **Anime 2×**, **Photo 2×**, or **Quick Upscale**. For a low-resolution clip, **Restore Video 4×** selects NanoVSR and high encoder quality.

After choosing an engine, size, and export settings, return to **Engine → Presets → Save Preset…** to name the combination. Pick it from **Saved Presets** for another batch. Use **Remove Preset** to delete an entry or **Restore Defaults** for one group of settings.

The app remembers the last options, destination, and app preferences between launches. A preset stores the processing and format options. Reference images belong to the active batch.

## Output and filenames

Choose **Beside Originals** or **Folder…** in **Export → Save To**. **Filename Suffix** controls the text after the source name, with ` – Upscaled` as the default. The app adds a number if the name already exists. It writes a new output and keeps the source.

| Input | Export choices |
| --- | --- |
| Still image | PNG with alpha or JPEG with adjustable quality. Transparent areas are flattened onto white for JPEG. |
| Animated GIF | GIF with playback speed and loop controls. |
| Video | MP4 with H.264 or HEVC, a quality setting, and optional primary audio. |

When a job finishes, right-click its row for **Open Result** or **Show Result in Finder**, or click **Show in Finder** in the toolbar for all completed files. **File → Recent Exports** opens a previous result.
