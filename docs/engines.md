# Engines and models

The engine decides how the app scales pixels. The model is the set of weights an AI engine uses. Try the same crop with two choices before processing a whole folder.

| Engine | Try it on | What to look for |
| --- | --- | --- |
| **MetalFX** | Quick drafts, resize jobs, and a first smoke test | Clean spatial scaling using Apple's GPU. Use an AI engine when denoising or model-based texture reconstruction matters. |
| **Real-CUGAN** | Anime, comics, line art, and flat colors | Start at 2× and keep denoise low. Increase it for visible compression artifacts and check whether thin strokes survive. |
| **Real-ESRGAN** | Illustrations that benefit from crisper textures | Compare fine edges and text. Some models produce stronger sharpening or invented detail. |
| **RealSR** | Photos, portraits, and live-action frames | Compare the clean and JPEG-oriented choices on hair, skin, and edges. |
| **RIFE** | Motion in GIFs and videos | The **Smoother motion** option creates new frames. Watch for artifacts around cuts, subtitles, and overlapping objects. |

## Example settings

- **Anime still** · Try **Real-CUGAN**, **2×**, and **Low** noise reduction. Zoom in on outlines and lettering.
- **Compressed family photo** · Try **RealSR (Photos)** with its JPEG option. Compare faces and texture against the original at normal viewing size.
- **Small animated GIF** · Start with **2×** and keep smoother motion off for the first run. Compare a second run with interpolation enabled if you want smoother movement. **Smaller GIFs** runs Gifsicle when installed.
- **4K wallpaper** · Use **Fit to… → 4K** and leave **Fit inside (keep aspect)** on to preserve proportions. A source with a different aspect ratio may come out smaller on one axis. Check the displayed dimensions.
- **Short video** · Try a few seconds at **2×** before scaling the whole video. Review the resulting dimensions, audio, motion, and file size.

## Optional models

The pinned Real-ESRGAN archive supplies its standard model set. Additional photo or anime choices require the matching `.param` and `.bin` files. To try the optional pack, review its terms, then run the helper against the `models` folder beside the extracted Real-ESRGAN binary before assembling the app. The helper also uses Python and a temporary virtual environment for conversion.

```sh
scripts/fetch-extra-models.sh build-mac/engines/realesrgan/models
```

The helper downloads or converts AnimeSharp, AnimeJaNai, a general Real-ESRGAN model, and community photo models including LSDIR, UltraSharp, and Siax. Terms vary by model and some restrict commercial use. [AnimeSharp](https://huggingface.co/Kim2091/AnimeSharp) · [AnimeJaNai](https://github.com/the-database/mpv-upscale-2x_animejanai) · [Photo model files](https://github.com/TransparentLC/realesrgan-gui/releases/tag/additional-models) · [Model documentation](https://upscale.wiki/)

For a missing model or engine, check the file layout and run the app's [engine check](troubleshooting.md).

## Pick a stock model

| Content | First choice | Next comparison |
| --- | --- | --- |
| Clean anime lines | Real-CUGAN Pro with denoise off | SE or MetalFX |
| JPEG artifacts on animation | Real-CUGAN at a low denoise level | Increase one step and check thin lines |
| Clean photos | RealSR clean-source model | Real-ESRGAN x4plus |
| Compressed photos | JPEG-oriented RealSR | Compare the clean model on skin and text |
| Fast size check | MetalFX | Compare the AI engine you plan to use for the full batch |

MetalFX is a spatial scaler and has no model files. Real-CUGAN and RealSR are separate tools even when invoked from the same wizard. The stock engine archives in the build guide are enough for these comparisons. An optional weight must match the Real-ESRGAN helper's NCNN format and expected file names.

When adding models, keep the `.param` and `.bin` pair together. Assemble again so both land under `Contents/Resources/engines/realesrgan-ncnn-vulkan/models`. RIFE's weights live in its own folders and are selected separately from the upscaler.
