#!/usr/bin/env python3
"""Convert pinned Real-CUGAN, Real-ESRGAN, RealSR and RIFE weights to Core ML."""

import argparse
import hashlib
import io
from pathlib import Path
import subprocess

import coremltools as ct
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".build" / "requested-models"
MODELS = ROOT / "Sources" / "UpscaleCore" / "Models"
RAW = "https://raw.githubusercontent.com/"
CUGAN = RAW + "nihui/realcugan-ncnn-vulkan/395302c5c70f1bff604c974e92e0a87e45c9f9ee/models/models-se/"
REALSR = RAW + "nihui/realsr-ncnn-vulkan/b7f890ee2704ccea76c73d9fd4d5b3298dd1beca/models/"
RIFE = RAW + "nihui/rife-ncnn-vulkan/a7532fc3f9f8f008cd6eecd6f2ffe2a9698e0cf7/models/rife-v4.6/"
ESRGAN = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth"
CUGAN_CHECKPOINTS = {
    "CUGAN": ("up2x-no-denoise", "7f135a712830b16678cb8247b9517308c5f3858fca9b10e1c3ad5ef6e261de0c"),
    "CUGANLow": ("up2x-denoise1x", "09373c4fddfd2a57fb4af5e516eba1b4c9caa132fd52ffd01bcaefee543bf7f6"),
    "CUGANMedium": ("up2x-denoise2x", "47427a52badebfbd7bb6db97196a2844c553f7f2bb93c9527b26347bea0430e7"),
    "CUGANHigh": ("up2x-denoise3x", "610ebae63f388fe6f39615cc5f4eaeb038d5aa6ba8b299ba3b989f7f7a1a280a"),
}
REALSR_CHECKPOINTS = {
    "RealSR": ("DF2K", "a3f5eb53906ef54d5c5d125b2c9dd5f570d9dbb779e3d934df14b5375fd923c1"),
    "RealSRJPEG": ("DF2K_JPEG", "e862e88c3f346a3b8506d839633f5e2a16461bb8bfb3e211152f40d807a4f51c"),
}


def fetch(url, digest):
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f"{digest}-{url.rsplit('/', 1)[-1]}"
    if not path.exists():
        subprocess.run(["curl", "-fsSL", "--retry", "2", url, "-o", str(path)], check=True)
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError(f"SHA-256 mismatch for {path}")
    return path


def warp(image, flow):
    height, width = image.shape[-2:]
    x = torch.arange(width, device=image.device).view(1, 1, -1) + flow[:, 0]
    y = torch.arange(height, device=image.device).view(1, -1, 1) + flow[:, 1]
    grid = torch.stack((2 * x / (width - 1) - 1, 2 * y / (height - 1) - 1), dim=-1)
    return F.grid_sample(image, grid, padding_mode="border", align_corners=True)


class NCNNGraph(nn.Module):
    """Import the operator subset used by these pinned, FP16 NCNN graphs."""

    def __init__(self, base, param_digest, bin_digest):
        super().__init__()
        param = fetch(base + ".param", param_digest)
        weights = io.BytesIO(fetch(base + ".bin", bin_digest).read_bytes())
        self.layers = nn.ModuleDict()
        self.graph = []
        for line in param.read_text().splitlines()[2:]:
            op, name, input_count, output_count, *fields = line.split()
            inputs = fields[:int(input_count)]
            outputs = fields[int(input_count):int(input_count) + int(output_count)]
            attrs = {}
            for field in fields[len(inputs) + len(outputs):]:
                key, value = field.split("=")
                attrs[int(key)] = (list(map(float, value.split(",")[1:])) if "," in value else float(value))
            self.graph.append((op, name, inputs, outputs, attrs))
            if op not in ("Convolution", "Deconvolution", "InnerProduct"):
                continue
            channels, k = int(attrs[0]), int(attrs[1])
            count = int(attrs[2 if op == "InnerProduct" else 6])
            if weights.read(4) != bytes.fromhex("476b3001"):
                raise ValueError(f"Expected FP16 weights in {name}")
            values = np.frombuffer(weights.read(count * 2), dtype="<f2").astype(np.float32)
            weights.read((-count * 2) % 4)
            has_bias = bool(attrs[1 if op == "InnerProduct" else 5])
            if op == "InnerProduct":
                layer = nn.Conv2d(count // channels, channels, 1, bias=has_bias)
            else:
                layer = (nn.Conv2d if op == "Convolution" else nn.ConvTranspose2d)(
                    count // (channels * k * k), channels, k, stride=int(attrs.get(3, 1)),
                    padding=int(attrs.get(4, 0)), bias=has_bias
                )
            if op == "Deconvolution":
                # NCNN stores deconvolution weights output-channel first.
                values = values.reshape(channels, -1, k, k).transpose(1, 0, 2, 3).copy()
            layer.weight = nn.Parameter(torch.from_numpy(values.reshape(layer.weight.shape)), requires_grad=False)
            if has_bias:
                bias = np.frombuffer(weights.read(channels * 4), dtype="<f4").copy()
                layer.bias = nn.Parameter(torch.from_numpy(bias), requires_grad=False)
            self.layers[name] = layer
        if weights.read(1):
            raise ValueError(f"Unused weights in {param}")

    def forward(self, *inputs):
        initial = iter(inputs)
        blobs = {}
        for op, name, sources, outputs, a in self.graph:
            values = [blobs[key] for key in sources]
            x = values[0] if values else None
            if op == "Input":
                result = next(initial)
            elif op in ("Convolution", "Deconvolution", "InnerProduct"):
                result = self.layers[name](x)
                match int(a.get(9, 0)):
                    case 0: pass
                    case 1: result = F.relu(result)
                    case 2: result = F.leaky_relu(result, a[-23310][0])
                    case 4: result = torch.sigmoid(result)
                    case _: raise ValueError(f"Unknown activation in {name}")
            elif op == "Split":
                result = x
            elif op == "Pooling" and a[0] == 1 and a[4] == 1:
                result = x.mean((2, 3), keepdim=True)
            elif op == "Crop":
                slices = [slice(None)] * 4
                for start, end, axis in zip(a[-23309], a[-23310], a[-23311], strict=True):
                    index = int(axis) if axis < 0 else int(axis) + 1
                    slices[index] = slice(int(start), int(end))
                result = x[tuple(slices)]
            elif op == "Concat":
                result = torch.cat(values, dim=1)
            elif op == "Interp":
                mode = {1: "nearest", 2: "bilinear"}[int(a[0])]
                if mode == "bilinear" and a[1] == a[2] < 1:
                    # With dimensions divisible by the stride, the bilinear sample
                    # is the average of the four pixels at each block's center.
                    stride = int(1 / a[1])
                    offset = stride // 2 - 1
                    result = F.avg_pool2d(x[:, :, offset:, offset:], 2, stride)
                else:
                    result = F.interpolate(x, scale_factor=(a[1], a[2]), mode=mode)
            elif op == "BinaryOp":
                y = a[2] if a.get(1) else values[1]
                match int(a.get(0, 0)):
                    case 0: result = x + y
                    case 2: result = x * y
                    case 3: result = x / y
                    case 7: result = y - x
                    case _: raise ValueError(f"Unknown binary operator in {name}")
            elif op == "Eltwise" and a[0] == 1:
                p, q = a[-23301]
                result = x * p + values[1] * q
            elif op == "PixelShuffle":
                result = F.pixel_shuffle(x, int(a[0]))
            elif op == "ReLU":
                result = F.leaky_relu(x, a[0])
            elif op == "Sigmoid":
                result = torch.sigmoid(x)
            elif op == "rife.Warp":
                result = warp(x, values[1])
            else:
                raise ValueError(f"Unknown operator {op}")
            blobs.update(dict.fromkeys(outputs, result))
        return result


class Spatial(nn.Module):
    def __init__(self, graph, crop=0, residual=False):
        super().__init__()
        self.graph = graph
        self.crop = crop
        self.residual = residual

    def forward(self, x):
        output = self.graph(x)
        if self.residual:
            output = F.pixel_shuffle(output, 4) + F.interpolate(x, scale_factor=4, mode="nearest")
        if self.crop:
            output = output[:, :, self.crop:-self.crop, self.crop:-self.crop]
        return output.clamp(0, 1) * 255


class Midpoint(nn.Module):
    def __init__(self, graph):
        super().__init__()
        self.graph = graph

    def forward(self, first, second):
        return self.graph(first, second, torch.full_like(first[:, :1], 0.5)).clamp(0, 1) * 255


def convert(name):
    if name in CUGAN_CHECKPOINTS:
        file, digest = CUGAN_CHECKPOINTS[name]
        source = CUGAN + file
        graph = NCNNGraph(source, "4b3b5c5710ad1d00503c8243417aa75f13fe497723e8b4952e8b1abfc08f9b84", digest)
        model, side, tile = Spatial(graph, crop=12), 176, 128
        author, license_id = "bilibili", "MIT"
    elif name in REALSR_CHECKPOINTS:
        folder, digest = REALSR_CHECKPOINTS[name]
        source = REALSR + f"models-{folder}/x4"
        graph = NCNNGraph(source, "a7f31e75518ad279c179202bf77da9eca3141124a67e5261d97235849e6cc323", digest)
        model, side, tile = Spatial(graph, crop=128), 144, 80
        author, license_id = "Tencent and Real-SR contributors", "Apache-2.0"
    elif name == "RealESRGAN":
        source = ESRGAN
        checkpoint = fetch(source, "b8a8376811077954d82ca3fcf476f1ac3da3e8a68a4f4d71363008000a18b75d")
        weights = torch.load(checkpoint, map_location="cpu", weights_only=True)["params"]
        layers = []
        for i in range(35):
            weight = weights[f"body.{i}.weight"]
            if i % 2 == 0:
                layer = nn.Conv2d(weight.shape[1], weight.shape[0], 3, padding=1)
                layer.bias = nn.Parameter(weights[f"body.{i}.bias"])
            else:
                layer = nn.PReLU(weight.numel())
            layer.weight = nn.Parameter(weight)
            layers.append(layer)
        model, side, tile = Spatial(nn.Sequential(*layers), crop=72, residual=True), 196, 160
        author, license_id = "Xintao Wang and Real-ESRGAN contributors", "BSD-3-Clause"
    else:
        source = RIFE + "flownet"
        graph = NCNNGraph(source, "724569596bcd1e7b9fa50455c604777ebed99746d2ef40aa86e31b5725f1053c",
                          "f334ed2260149ce0188a6dcf049844e8b0cdd912e01cbcfb63553157d2508958")
        model = Midpoint(graph)
        author, license_id = "Zhewei Huang and RIFE contributors; NCNN conversion by nihui", "MIT"

    if name == "RIFE46":
        samples = tuple(torch.rand(1, 3, 64, 96) for _ in range(2))
        shape = ct.Shape((1, 3, ct.RangeDim(32, 1920, default=64), ct.RangeDim(32, 1920, default=96)))
        inputs = [ct.ImageType(name=key, shape=shape, scale=1 / 255) for key in ("first", "second")]
        with torch.no_grad():
            traced = torch.jit.trace(model.eval(), samples)
            other = tuple(torch.rand(1, 3, 96, 64) for _ in range(2))
            torch.testing.assert_close(traced(*other), model(*other))
    else:
        samples = (torch.rand(1, 3, side, side),)
        inputs = [ct.ImageType(name="rgb", shape=samples[0].shape, scale=1 / 255)]
        with torch.no_grad():
            traced = torch.jit.trace(model.eval(), samples)
            factor = 2 if name in CUGAN_CHECKPOINTS else 4
            assert traced(*samples).shape == (1, 3, tile * factor, tile * factor)
    result = ct.convert(torch.jit.freeze(traced), inputs=inputs, outputs=[ct.ImageType(name="result")],
                        minimum_deployment_target=ct.target.macOS15, skip_model_load=True)
    result.author = author
    result.license = license_id
    result.short_description = f"Core ML conversion of {source}"
    result.save(str(MODELS / (name + ".mlpackage")))


if __name__ == "__main__":
    names = [*CUGAN_CHECKPOINTS, "RealESRGAN", *REALSR_CHECKPOINTS, "RIFE46"]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("models", nargs="*", metavar="MODEL", help=", ".join(names))
    requested = parser.parse_args().models or names
    if unknown := set(requested) - set(names):
        parser.error(f"Unknown models: {', '.join(sorted(unknown))}")
    torch.set_num_threads(4)
    for name in requested:
        print(f"Converting {name}", flush=True)
        convert(name)
