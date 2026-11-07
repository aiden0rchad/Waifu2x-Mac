#!/usr/bin/env python3
"""Regenerate the checked-in MIT model files; requires coremltools 9.0."""
import hashlib
import re
import struct
from pathlib import Path
from urllib.request import urlopen

import numpy as np
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder
from coremltools.models.utils import _convert_neural_network_spec_weights_to_fp16, save_spec

DEST = Path(__file__).resolve().parents[1] / "Sources/UpscaleCore/Models"
TILE = 192
RAW = "https://raw.githubusercontent.com/"


def upstream(path, sha256):
    with urlopen(RAW + path, timeout=30) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != sha256:
        raise ValueError(f"Checksum mismatch: {path}")
    return data


def builder(halo):
    side = TILE + 2 * halo
    model = NeuralNetworkBuilder(
        [("rgb", datatypes.Array(3, side, side))], [("result", datatypes.Array(3, TILE * 2, TILE * 2))]
    )
    model.set_pre_processing_parameters(image_input_names=["rgb"], image_scale=1 / 255)
    return model


def conv(model, source, dest, weights, bias=None, *, padding="valid", stride=1):
    h, w, channels, outputs = weights.shape
    model.add_convolution(dest, channels, outputs, h, w, stride, stride, padding, 1, weights, bias,
                          bias is not None, is_deconv=stride == 2, input_name=source, output_name=dest)


def save(model, name, author, source):
    model.add_scale("bytes", np.array([255]), None, False, "unit", "result")
    feature = model.spec.description.output[0].type
    feature.ClearField("multiArrayType")
    feature.imageType.width = feature.imageType.height = TILE * 2
    feature.imageType.colorSpace = 20  # Core ML ImageFeatureType.RGB
    model.spec.description.metadata.author = author
    model.spec.description.metadata.license = "MIT"
    model.spec.description.metadata.shortDescription = source
    save_spec(_convert_neural_network_spec_weights_to_fp16(model.spec), str(DEST / (name + ".mlmodel")))


def acnet(name, variant, blocks):
    source = "TianZerL/Anime4KCPP/fe187e020c8e57c6885511344a8705c292a92612"
    data = upstream(source + "/core/internal/AC/Core/Internal/Model/Param/ACNet.p",
                    "982de63c9467213a62992620da5e8d0ba1d50f4081fc714ca7c4add66f6348da").decode()

    def array(key):
        values = re.search(f"ACNet_F8B{blocks}{variant}_NHWC_" + key + r"\[\] = \{([^}]+)\}", data)[1]
        return np.fromstring(values.replace("f", "").replace(",", " "), sep=" ", dtype=np.float32)

    kernels, biases, alphas = (array(key) for key in ("kernels", "biases", "alphas"))
    assert (kernels.size, biases.size, alphas.size) == (360 + 576 * blocks, 12 + 8 * blocks, 8 + 8 * blocks)
    halo = blocks + 2
    model = builder(halo)
    # Infer luminance with ACNet; carry the original chroma through bilinear enlargement.
    conv(model, "rgb", "luma", np.array([.299, .587, .114]).reshape(1, 1, 3, 1))
    previous = "luma"
    offset = 0
    for i, (channels, outputs) in enumerate([(1, 8)] + [(8, 8)] * blocks + [(8, 4)]):
        count = channels * outputs * 9
        weights = kernels[offset:offset + count].reshape(outputs, 3, 3, channels).transpose(1, 2, 3, 0)
        conv(model, previous, f"conv{i}", weights, biases[i * 8:i * 8 + outputs], padding="same")
        offset += count
        if outputs == 8:
            previous = f"activation{i}"
            model.add_activation(previous, "PRELU", f"conv{i}", previous, alphas[i * 8:i * 8 + 8])

    model.add_reorganize_data("shuffle", f"conv{blocks + 1}", "residual", mode="PIXEL_SHUFFLE", block_size=2)
    model.add_upsample("base", 2, 2, "luma", "lumaNearest")
    model.add_elementwise("sharpLuma", ["lumaNearest", "residual"], "sharpLuma", "ADD")
    model.add_clip("lumaClip", "sharpLuma", "validLuma")
    model.add_upsample("smoothLuma", 2, 2, "luma", "smoothLuma", mode="BILINEAR",
                       linear_upsample_mode="ALIGN_CORNERS_FALSE")
    model.add_scale("negativeLuma", np.array([-1]), None, False, "smoothLuma", "negativeLuma")
    model.add_elementwise("lumaDelta", ["validLuma", "negativeLuma"], "lumaDelta", "ADD")
    conv(model, "lumaDelta", "rgbDelta", np.ones((1, 1, 1, 3)))
    model.add_upsample("smoothRGB", 2, 2, "rgb", "smoothRGB", mode="BILINEAR",
                       linear_upsample_mode="ALIGN_CORNERS_FALSE")
    model.add_elementwise("sharpRGB", ["smoothRGB", "rgbDelta"], "sharpRGB", "ADD")
    model.add_clip("rgbClip", "sharpRGB", "validRGB")
    model.add_crop("tile", *([2 * halo] * 4), [0, 0], ["validRGB"], "unit")
    save(model, name, "TianZerL", source + f" / ACNet F8B{blocks}{variant}")


def waifu2x(name, folder, checksum):
    source = "nihui/waifu2x-ncnn-vulkan/64914665c45893135c9e50c1c296170a121b9f77"
    data = upstream(source + f"/models/models-upconv_7_{folder}/scale2.0x_model.bin", checksum)
    model = builder(7)
    offset, previous = 0, "rgb"
    features = [3, 16, 32, 64, 128, 128, 256, 3]
    for i, (channels, outputs) in enumerate(zip(features, features[1:])):
        k = 4 if i == 6 else 3
        count = channels * outputs * k * k
        assert struct.unpack_from("<I", data, offset)[0] == 0x01306B47  # NCNN float16 tag
        weights = np.frombuffer(data, "<f2", count, offset + 4).astype(np.float32)
        weights = weights.reshape(outputs, channels, k, k).transpose(2, 3, 1, 0)
        offset += 4 + 2 * count
        bias = np.frombuffer(data, "<f4", outputs, offset)
        offset += 4 * outputs
        conv(model, previous, f"conv{i}", weights, bias, stride=2 if i == 6 else 1)
        if i < 6:
            previous = f"activation{i}"
            model.add_activation(previous, "LEAKYRELU", f"conv{i}", previous, [0.1])

    assert offset == len(data)
    model.add_crop("tile", 3, 3, 3, 3, [0, 0], ["conv6"], "uncapped")
    model.add_clip("clip", "uncapped", "unit")
    save(model, name, "nagadomi; NCNN conversion by nihui", source + " / UpConv_7 " + folder.capitalize())


if __name__ == "__main__":
    acnet("Anime4K", "", 4)
    acnet("Anime4KRestore", "_Box_HDN", 18)
    waifu2x("Waifu2xPhoto", "photo", "25a2bb25b29e43e63179aac216cd87690791243a436328506d4ef9fca88ee962")
    waifu2x("Waifu2xArt", "anime_style_art_rgb", "27d880903ff81390a3b4a900b67af3381c465279e34297546c9a58781855f7ef")
