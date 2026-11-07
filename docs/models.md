# Bundled models

The Swift application uses AGPL-3.0. The models retain their MIT, Apache-2.0, or BSD-3-Clause terms and copyright notices. Find the files below in `Sources/UpscaleCore/Models/` in the native source checkout and next to the models in the app bundle.

| In the app | Upstream source | Notices |
| --- | --- | --- |
| **Anime4K** | TianZerL's [Anime4KCPP core ACNet F8B4](https://github.com/TianZerL/Anime4KCPP/blob/fe187e020c8e57c6885511344a8705c292a92612/core/internal/AC/Core/Internal/Model/Param/ACNet.p), retrained for [Anime4KCPP 3.2.0](https://github.com/TianZerL/Anime4KCPP/releases/tag/v3.2.0) in May 2026. The GPL video module isn't included. | `Anime4KCPP-MIT.txt` |
| **Anime4K Restore** | TianZerL's [ACNet F8B18 Box HDN](https://github.com/TianZerL/Anime4KCPP/wiki/Model). The larger variant is trained with box degradation and mild denoising. It uses the same pinned Anime4KCPP core revision as Anime4K. | `Anime4KCPP-MIT.txt` |
| **Waifu2x Art** | nagadomi's [Waifu2x UpConv_7 art model](https://github.com/nagadomi/waifu2x/tree/cc385f97a9debfe611316aabfd5d8bb30ba2dbeb/models/upconv_7/art), using nihui's [NCNN conversion](https://github.com/nihui/waifu2x-ncnn-vulkan/tree/64914665c45893135c9e50c1c296170a121b9f77/models/models-upconv_7_anime_style_art_rgb). | `Waifu2x-MIT.txt` · `Waifu2x-NCNN-MIT.txt` |
| **Waifu2x Photo** | nagadomi's [Waifu2x UpConv_7 photo model](https://github.com/nagadomi/waifu2x/tree/cc385f97a9debfe611316aabfd5d8bb30ba2dbeb/models/upconv_7/photo), using nihui's [NCNN conversion of the 2× weights](https://github.com/nihui/waifu2x-ncnn-vulkan/tree/64914665c45893135c9e50c1c296170a121b9f77/models/models-upconv_7_photo). | `Waifu2x-MIT.txt` · `Waifu2x-NCNN-MIT.txt` |
| **Real-CUGAN** | bilibili’s [Real-CUGAN](https://github.com/bilibili/ailab/tree/main/Real-CUGAN). The four 2× SE checkpoints come from [nihui’s pinned NCNN conversion](https://github.com/nihui/realcugan-ncnn-vulkan/tree/395302c5c70f1bff604c974e92e0a87e45c9f9ee/models/models-se). | `Real-CUGAN-MIT.txt` · `Real-CUGAN-NCNN-MIT.txt` |
| **Real-ESRGAN** | Xintao Wang et al., [AnimeVideo v3 checkpoint](https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0). | `Real-ESRGAN-BSD-3-Clause.txt` |
| **RealSR** and **RealSR JPEG** | Tencent’s [Real-SR](https://github.com/Tencent/Real-SR), using [nihui’s pinned NCNN DF2K and DF2K_JPEG conversions](https://github.com/nihui/realsr-ncnn-vulkan/tree/b7f890ee2704ccea76c73d9fd4d5b3298dd1beca/models). These graphs and weights were translated to fixed-tile FP16 Core ML packages. | `RealSR-Apache-2.0.txt` · `RealSR-NCNN-MIT.txt` |
| **RIFE 4.6** | Zhewei Huang et al., [Practical-RIFE](https://github.com/hzwer/Practical-RIFE). The bundled midpoint model comes from [nihui’s pinned v4.6 NCNN conversion](https://github.com/nihui/rife-ncnn-vulkan/tree/a7532fc3f9f8f008cd6eecd6f2ffe2a9698e0cf7/models/rife-v4.6). | `RIFE-MIT.txt` · `RIFE-NCNN-MIT.txt` |
| **NanoVSR** | Filip Pawlicki, Marcel Kańduła, Marcin Pucek, and Kamil Dobies. [NanoVSR-226k checkpoint v1.0](https://github.com/filippawlicki/nanovsr/releases/tag/v1.0), released July 2026. [Paper](https://doi.org/10.1007/978-3-032-37356-4_34). | `NanoVSR-MIT.txt` |
| **NanoVSR Detail** | [NanoVSR-644k checkpoint v1.0](https://github.com/filippawlicki/nanovsr/releases/tag/v1.0), with 48 feature channels and 12 blocks. | `NanoVSR-MIT.txt` |
| **SAFMN++ Light** | Long Sun et al., [official Light checkpoint](https://github.com/sunny2109/SAFMN/tree/1a412066e927da640bc7e2a53ea60f9ffc134241/AIS2024-RTSR), identical to the [Apache-2.0 checkpoint on Hugging Face](https://huggingface.co/Meloo/SAFMN/blob/f3ae915508fae452051728b99f069d1817d37b01/AIM24-VSR-SAFMNPP/light_safmnpp.pth). The converter adapts the original pooling to fixed, overlapping tiles and compiles the graph to FP16 Core ML. | `SAFMN-Apache-2.0.txt` |

The models run through Core ML. The native frame pipeline uses ACNet for luminance and interpolates chroma. Waifu2x Art and Photo use different RGB scale-only checkpoints; their noise and detail controls are separate filters. Both NanoVSR variants use forward and backward passes in overlapping frame windows and preserve source timestamps. They do not generate intermediate frames. SAFMN++ Light runs one frame at a time and stitches the center of each tile. Real-CUGAN blends overlapping tile edges. Real-ESRGAN and RealSR also render in tiles with surrounding context. RIFE runs on two source frames at a time with the timestep fixed at 0.5.

The Core ML files are checked in. To regenerate them on a Mac with Python 3.12:

```sh
python3.12 -m venv .build/model-tools
.build/model-tools/bin/pip install coremltools==9.0 torch==2.8.0 einops==0.8.2
.build/model-tools/bin/python scripts/convert-models.py
.build/model-tools/bin/python scripts/convert-video-model.py
.build/model-tools/bin/python scripts/convert-restoration-models.py
```

The converters pin upstream revisions and verify SHA-256 checksums before converting the model inputs.

## Adding another engine

Check the terms for the code, the exact checkpoint, and the bundled dependencies separately. Preserve the license and copyright notices and document the source revision. Follow the applicable redistribution terms when converting a model. [Optional AI downloads and licenses](optional-engines.md#downloads-and-licenses)
