#!/bin/bash
# Download extra anime models for the Real-ESRGAN engine and convert them to the
# ncnn format realesrgan-ncnn-vulkan loads (<name>.param/.bin with blobs "data"/"output").
#   usage: scripts/fetch-extra-models.sh <realesrgan-models-dir>
# Models (both CC BY-NC-SA 4.0, non-commercial use only):
#   4x-AnimeSharp  by Kim2091  https://huggingface.co/Kim2091/AnimeSharp (official ncnn files)
#   AnimeJaNai HD V3 / V3 Sharp / SD V1  by the-database
#                  https://github.com/the-database/mpv-upscale-2x_animejanai (release 3.0.0, ONNX)
# AnimeJaNai is converted with pnnx (pip) in a temporary virtualenv.
set -euo pipefail

OUT=${1:?usage: fetch-extra-models.sh <realesrgan-models-dir>}
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

echo "==> 4x-AnimeSharp"
for ext in param bin; do
    curl -fsSL -o "$OUT/4x-AnimeSharp.$ext" "https://huggingface.co/Kim2091/AnimeSharp/resolve/main/NCNN/4x-AnimeSharp-fp16.$ext"
done

echo "==> AnimeJaNai (download + convert)"
gh release download 3.0.0 -R the-database/mpv-upscale-2x_animejanai -p '2x_AnimeJaNai_HD_V3_ModelsOnly.zip' -D "$WORK"
unzip -q -o "$WORK/2x_AnimeJaNai_HD_V3_ModelsOnly.zip" -d "$WORK"
python3 -m venv "$WORK/venv" && "$WORK/venv/bin/pip" -q install pnnx
J="$WORK/2x_AnimeJaNai_HD_V3_ModelsOnly"
for pair in "2x_AnimeJaNai_HD_V3_Compact:2x-AnimeJaNai-HD-V3" \
            "2x_AnimeJaNai_HD_V3Sharp1_Compact:2x-AnimeJaNai-HD-V3-Sharp" \
            "2x_AnimeJaNai_SD_V1beta34_Compact:2x-AnimeJaNai-SD-V1"; do
    src=${pair%%:*}; dst=${pair##*:}
    "$WORK/venv/bin/pnnx" "$J/$src.onnx" 'inputshape=[1,3,128,128]' 'fp16=1' > "$WORK/$src.log" 2>&1
    # realesrgan-ncnn-vulkan is built without the Clip layer and expects blobs "data"/"output":
    # drop the trailing clamp (the program clamps when converting to 8-bit) and rename the blobs.
    python3 - "$J/$src.ncnn.param" "$OUT/$dst.param" <<'EOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
L = open(src).read().splitlines()
L = [l.replace(' in0 ', ' data ') if l.split()[:1] == ['Input'] else l for l in L]
L = [' '.join('data' if t == 'in0' else t for t in l.split()) if i > 1 else l for i, l in enumerate(L)]
clip = [i for i, l in enumerate(L) if l.startswith('Clip')]
if clip:
    t = L[clip[0]].split(); clip_in = t[4]
    del L[clip[0]]
    for i in range(2, len(L)):
        t = L[i].split(); nin, nout = int(t[2]), int(t[3])
        outs = t[4 + nin:4 + nin + nout]
        if clip_in in outs:
            t[4 + nin + outs.index(clip_in)] = 'output'; L[i] = ' '.join(t)
    lc, bc = map(int, L[1].split()); L[1] = f'{lc - 1} {bc - 1}'
else:
    L = [' '.join('output' if t == 'out0' else t for t in l.split()) if i > 1 else l for i, l in enumerate(L)]
open(dst, 'w').write('\n'.join(L) + '\n')
EOF
    cp "$J/$src.ncnn.bin" "$OUT/$dst.bin"
done

echo "==> Photo models"
# realesr-general-x4v3 is BSD-3-Clause (Real-ESRGAN). The community models'
# licenses (including CC BY-NC-SA 4.0 / CC BY 4.0) are listed on upscale.wiki;
# this packaging assumes non-commercial use.
for model in realesr-general-x4v3 4xLSDIRplus 4x-UltraSharp-opt-fp16 4x-NMKD-Siax-200k; do
    for ext in param bin; do
        curl -fsSL -o "$OUT/$model.$ext" \
            "https://github.com/TransparentLC/realesrgan-gui/releases/download/additional-models/$model.$ext"
    done
done

echo "done: $(ls "$OUT" | tr '\n' ' ')"
