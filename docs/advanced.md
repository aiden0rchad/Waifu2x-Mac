# Advanced settings

Open **Advanced…** from **Upscaler** or **Options**. The available controls depend on the selected engine and media.

## Engine

- **Tile size** controls how much of an image the AI engine processes at once. Start at **Auto**. Try 128 or 64 if the process runs out of GPU memory. Smaller tiles can take longer.
- **GPU** normally stays on **Automatic**. A manually selected ID must exist for the engine you're using.
- **TTA mode** can improve some results by processing transformed copies. Try it on one image because it adds substantial processing time.
- **Low memory**, **Balanced**, and **Fast** adjust worker counts. Use Low memory if multiple jobs compete for memory.
- **Model** determines which weights the engine uses. A listed optional model needs its matching files. [Model guide](engines.md)

## Output

Set the still-image format, quality, filename template, or whether to retain source names and parent folders. Check for name collisions before using a common output folder for inputs that share the same filename.

The panel also exposes **Overwrite existing files**, **Delete original after success**, and **Replace original file**. These settings can change or remove existing files. For first runs, keep them off and choose a dedicated output folder.

## Video and GIF

Choose H.264 or HEVC, CRF, and encoder speed preset. Encoder arguments are passed to FFmpeg, so an invalid argument can stop the encode after frames have been processed. Test changes on a short clip.

Video and GIF interpolation use RIFE. GIF optimization is a separate Gifsicle pass. [Motion recipes](motion.md)

## System

The app can keep the screen awake while a job is active using macOS `caffeinate`. Check **When finished** before starting an unattended batch, especially if a previous job used a sleep or shutdown action.
