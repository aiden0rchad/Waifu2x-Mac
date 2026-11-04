# Images and wallpapers

Keep one small reference image in the queue while you tune settings. Save comparisons into a separate folder so you can switch between them in Quick Look.

## Anime and line art

1. Add a PNG or JPEG, choose **Best for anime (Real-CUGAN)**, and start with **Pro** at **2×**.
2. Set noise reduction to **Off** for a clean original or **Low** for visible JPEG blocks. Options depend on the model.
3. Scroll to **Compare** and inspect diagonal edges, small text, and color transitions. Try the same crop with **MetalFX** to see whether the AI pass helps.
4. Save as PNG when checking outlines or gradients. Keep the source and output for comparison.

Here is a real engine result from the example illustration. Both thumbnails are displayed at the same width so you can compare the edges.

| Original · 240 × 150 | Real-CUGAN Pro · 480 × 300 |
| --- | --- |
| <img src="./assets/skyline.png" width="360" alt="Original skyline illustration"> | <img src="./assets/skyline-realcugan-2x.png" width="360" alt="Skyline illustration upscaled by Real-CUGAN"> |

[Download the input PNG](https://raw.githubusercontent.com/aiden0rchad/Waifu2x-Mac/main/docs/assets/skyline.png) · [Open the 2× result](https://raw.githubusercontent.com/aiden0rchad/Waifu2x-Mac/main/docs/assets/skyline-realcugan-2x.png)

## Photos and portraits

1. Open **Photos** and choose the JPEG-oriented RealSR model for a compressed input or the clean-source RealSR option for a clean image.
2. Compare at **2×** and inspect eyes, hair, signs, or distant objects. Look for doubled edges or texture that wasn't in the source.
3. If you have installed optional Real-ESRGAN photo weights, try them on the same crop and export to a separate file. [Model installation and choices](engines.md#optional-models)

## 4K wallpaper

Choose **Fit to… → 4K** for a 3840 × 2160 bounding box. A 1920 × 1080 input can fill it at 2×. A 1600 × 1200 input fitted inside the same box is 2880 × 2160. If you need a true 16:9 wallpaper with the subject framed intentionally, crop a copy to 16:9 before upscaling.

Very large targets can require several engine passes. Check the planned size and run one image before starting a folder. [Scale, targets, and output](settings.md)
