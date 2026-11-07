#!/usr/bin/env python3
"""Convert the pinned NanoVSR variants and SAFMN++ Light to Core ML."""
import argparse
import hashlib
import runpy
import tempfile
from pathlib import Path
from urllib.request import urlopen

import coremltools as ct
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

DEST = Path(__file__).resolve().parents[1] / "Sources/UpscaleCore/Models"
SOURCE = "https://github.com/filippawlicki/nanovsr"


def fetch(url, checksum, dest):
    with urlopen(url, timeout=30) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != checksum:
        raise ValueError(f"Checksum mismatch: {url}")
    dest.write_bytes(data)


class Propagate(nn.Module):
    def __init__(self, extract, network):
        super().__init__()
        self.extract, self.network = extract, network

    def forward(self, rgb, previous):
        return self.network(self.extract(rgb) + previous)


class Reconstruct(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.fusion = model.fusion
        self.upsample1, self.upsample2 = model.upsample1, model.upsample2
        self.last = model.conv_last

    def forward(self, rgb, past, future):
        fused = self.fusion(torch.cat((past, future), dim=1))
        detail = self.last(self.upsample2(self.upsample1(fused)))
        base = F.interpolate(rgb, scale_factor=4, mode="bilinear", align_corners=False)
        return (base + detail).clamp(0, 1) * 255


def convert(module, name, channels, variant, *, reconstruct=False):
    h = ct.RangeDim(8, 640, default=180)
    w = ct.RangeDim(8, 640, default=320)
    rgb = ct.ImageType(name="rgb", shape=(1, 3, h, w), scale=1 / 255, color_layout=ct.colorlayout.RGB)
    state = torch.zeros(1, channels, 180, 320)
    inputs = [rgb]
    example = [torch.zeros(1, 3, 180, 320), state]
    for key in (["past", "future"] if reconstruct else ["previous"]):
        inputs.append(ct.TensorType(name=key, shape=(1, channels, h, w), dtype=np.float16))
    if reconstruct:
        example.append(state)
        output = ct.ImageType(name="result", color_layout=ct.colorlayout.RGB)
    else:
        output = ct.TensorType(name="next_features", dtype=np.float16)
    traced = torch.jit.trace(module.eval(), tuple(example), check_trace=False)
    model = ct.convert(traced, inputs=inputs, outputs=[output], minimum_deployment_target=ct.target.macOS15,
                       skip_model_load=True)
    model.author = "Filip Pawlicki, Marcel Kańduła, Marcin Pucek, Kamil Dobies"
    model.license = "MIT"
    model.short_description = f"NanoVSR-{variant}, v1.0 — " + SOURCE
    model.save(DEST / (name + ".mlpackage"))


def nanovsr(temporary, variant):
    variants = {
        "226k": ("NanoVSR", 32, 8, "be3df12f2a0d99d9699656aa4a85a51c119663aa84c7040ac6580a0215d0b00e"),
        "644k": ("NanoVSRDetail", 48, 12, "515eec20ff589986fc0e0da18b363962b931008ebd848d0c8fb7e256ce200cf7"),
    }
    prefix, channels, blocks, checksum = variants[variant]
    source = temporary / "nanovsr.py"
    weights = temporary / f"nanovsr_{variant}.pth"
    fetch("https://raw.githubusercontent.com/filippawlicki/nanovsr/"
          "feab9d259977ace3be4fca659394c3043bcc34c5/models/nanovsr.py",
          "a7eae614f0dbfb5d9532d312d2eebdae0c560fd34de7dae2384c3d1b14e10125", source)
    fetch(SOURCE + "/releases/download/v1.0/" + weights.name, checksum, weights)
    model = runpy.run_path(str(source))["NanoVSR"](num_feat=channels, num_blocks=blocks).eval()
    model.load_state_dict(torch.load(weights, map_location="cpu", weights_only=True))
    model.switch_to_deploy()
    convert(Propagate(model.feat_extract, model.forward_net), prefix + "Forward", channels, variant)
    convert(Propagate(model.feat_extract, model.backward_net), prefix + "Backward", channels, variant)
    convert(Reconstruct(model), prefix + "Reconstruct", channels, variant, reconstruct=True)


class FixedSAFM(nn.Module):
    """Adapted from SimpleSAFM (SAFMN, Apache-2.0) for fixed 320-pixel tiles."""
    def __init__(self, original):
        super().__init__()
        self.proj, self.dwconv, self.out, self.act = original.proj, original.dwconv, original.out, original.act

    def forward(self, image):
        left, right = self.proj(image).chunk(2, dim=1)
        pooled = self.dwconv(F.max_pool2d(left, 8, 8))
        modulation = self.act(F.interpolate(pooled, size=(320, 320), mode="bilinear", align_corners=False))
        return self.out(self.act(torch.cat([right, modulation * left], dim=1)))


class SAFMNTile(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, rgb):
        features = self.model.to_feat(rgb)
        features = self.model.feats(features) + features
        pixels = self.model.to_img[0](features)[:, :, 64:-64, 64:-64]
        return (self.model.to_img[1](pixels).clamp(0, 1) * 255)


def safmn(temporary):
    revision = "1a412066e927da640bc7e2a53ea60f9ffc134241"
    base = f"https://raw.githubusercontent.com/sunny2109/SAFMN/{revision}/AIS2024-RTSR/"
    source, weights = temporary / "safmn.py", temporary / "safmn.pth"
    fetch(base + "light_safmnpp_arch.py", "a9c1388c91f00b79dd1472bf997aee8cf62cb21f49f522068f0e1e6a5f68e7ab", source)
    fetch(base + "pretrained_model/light_safmnpp.pth", "a542c92072cb25adab1f9cc5209d4f4f4ca8549db084e6703d2e032357cd50a7", weights)
    checkpoint = torch.load(weights, map_location="cpu", weights_only=True)["params_ema"]
    channels = checkpoint["to_feat.weight"].shape[0]
    expansion = checkpoint["feats.0.conv2.conv.0.weight"].shape[0] / channels
    model = runpy.run_path(str(source))["SAFMN_VIS24"](dim=channels, n_blocks=2, ffn_scale=expansion).eval()
    model.load_state_dict(checkpoint)
    sample = torch.rand(1, 3, 320, 320)  # 192-pixel tile and 64-pixel context per edge.
    expected = model(sample)[:, :, 256:-256, 256:-256].clamp(0, 1) * 255
    for block in model.feats:
        block.conv1 = FixedSAFM(block.conv1)
    torch.testing.assert_close(SAFMNTile(model)(sample), expected)
    traced = torch.jit.trace(SAFMNTile(model).eval(), sample, check_trace=False)
    result = ct.convert(traced, inputs=[ct.ImageType(name="rgb", shape=tuple(sample.shape), scale=1 / 255)],
                        outputs=[ct.ImageType(name="result")], minimum_deployment_target=ct.target.macOS15,
                        skip_model_load=True)
    result.author = "Long Sun et al."
    result.license = "Apache-2.0"
    result.short_description = "SAFMN++ Light, converted to FP16 Core ML with an overlap crop"
    result.save(DEST / "SAFMNLight.mlpackage")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("model", choices=("226k", "644k", "safmn"), nargs="*")
    models = parser.parse_args().model
    torch.set_num_threads(2)
    with tempfile.TemporaryDirectory() as temporary, torch.no_grad():
        for choice in models or ("226k", "644k", "safmn"):
            if choice == "safmn":
                safmn(Path(temporary))
            else:
                nanovsr(Path(temporary), choice)
