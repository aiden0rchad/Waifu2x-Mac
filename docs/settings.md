# Size, presets, and output

## Scale versus Fit to…

| Control | What it sets | Example |
| --- | --- | --- |
| **Scale** | Multiplies each input's width and height | 640 × 480 at 2× gives 1280 × 960 |
| **Fit to…** | Uses a selected width and height for the job | A 4:3 input fitted into 1920 × 1080 gives 1440 × 1080 |
| **Fit inside (keep aspect)** | Preserves proportions inside the chosen bounds | A portrait stays portrait inside a landscape target |

The wizard includes 1080p, 1440p, 4K, 8K, and an iPhone wallpaper preset. Use **Custom** to enter exact bounds. The interface indicates when a source is already larger than the target. Read the planned dimensions before starting the job.

Some engines reach larger ratios through repeated passes and a final resize. The comparison uses a center crop and follows the job's pass plan. Inspect full output before judging details near the edges.

## Presets

| Preset | Use it to start |
| --- | --- |
| **Anime wallpaper 4K** | A Real-CUGAN wallpaper workflow |
| **Photo restore** | The photo model workflow |
| **Quick preview** | A fast MetalFX comparison |
| **Smooth GIF** | Animated input with smoother motion |

Click **Save preset…** after tuning your settings, give it a descriptive name, and reopen it for similar jobs. Review size, format, and motion before reusing a preset on a different kind of input.

## Output and filenames

Choose **Next to the original files** or **Choose a folder…** in **Options**. A separate output folder is easiest for testing or processing a batch. Image quality applies according to the selected format. PNG is a good choice for lossless checks, while JPEG can be smaller for photos.

**Advanced… → Output** offers a file-name template, options for original names and parent folders, and controls for overwriting or replacing files. Enable replacement or deletion only after testing with a disposable copy. [Advanced settings](advanced.md#output)
