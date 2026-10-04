# -*- coding: utf-8 -*-
"""AI シャープ化モデル (realesr-animevideov3) の高速化候補を作り、画質を PC で比べる。

候補 (build/sr/fast/ に出力):
  fp32_t128 / fp32_t256 : 元の精度。タイルを大きくすると重なりの無駄が減る
  int8_*                : 静的量子化 (QDQ、重みはチャネル別)。実写のタイルで較正する
  fp16_*                : 半精度 (入出力は float32 のまま)

画質は fp32 の出力との PSNR と、小さい文字の拡大比較 (build/sr/fast/small_text.png) で見る。
速度は端末で測る (アプリの 設定 → 自己診断を許可 → selftest/ に置いて AIBENCH)。

  tools/.venv/Scripts/python tools/sr_quantize.py
"""

import glob
import json
import os
import random

import cv2
import numpy as np
import onnx
import onnxruntime as ort
import torch
from onnxruntime.quantization import (CalibrationDataReader, QuantFormat, QuantType,
                                      quantize_static)

import sr_eval as E

OUT = os.path.join(E.SR_DIR, "fast")
CALIB_TILES = 96


def export_anime(tile):
    m = E.SRVGGNetCompact(num_conv=16)
    sd = torch.load(os.path.join(E.SR_DIR, "realesr-animevideov3.pth"), map_location="cpu")
    m.load_state_dict(sd.get("params", sd))
    m.eval()
    path = os.path.join(OUT, f"fp32_t{tile}.onnx")
    torch.onnx.export(m, torch.zeros(1, 3, tile, tile), path, input_names=["input"],
                      output_names=["output"], opset_version=17, do_constant_folding=True,
                      dynamo=False)
    return path


def real_pages():
    """実写の紙面 (アプリと同じ補正 → 1/2 縮小 = AI の入力相当)。"""
    pages = []
    for d in ("eval_heldout", "eval_hard"):
        for jp in sorted(glob.glob(os.path.join(E.ROOT, "training_data", d, "*.json"))):
            meta = json.load(open(jp, encoding="utf-8"))
            if not meta.get("corners"):
                continue
            page = E.warp(cv2.imread(jp[:-5] + ".jpg"), meta["corners"])
            h, w = page.shape[:2]
            page = cv2.resize(page, (w // 2, h // 2), interpolation=cv2.INTER_AREA)
            pages.append(cv2.cvtColor(page, cv2.COLOR_BGR2RGB))
    return pages


class TileReader(CalibrationDataReader):
    def __init__(self, pages, tile, n):
        rng = random.Random(0)
        self.items = []
        for _ in range(n):
            p = rng.choice(pages)
            h, w = p.shape[:2]
            y, x = rng.randrange(0, h - tile), rng.randrange(0, w - tile)
            t = p[y:y + tile, x:x + tile].astype(np.float32) / 255.0
            self.items.append({"input": t.transpose(2, 0, 1)[None]})
        self.it = iter(self.items)

    def get_next(self):
        return next(self.it, None)


def quantize(fp32, pages, tile, act, name):
    out = os.path.join(OUT, f"{name}_t{tile}.onnx")
    pre = fp32[:-5] + "_pre.onnx"
    from onnxruntime.quantization.shape_inference import quant_pre_process
    quant_pre_process(fp32, pre)
    quantize_static(pre, out, TileReader(pages, tile, CALIB_TILES // (tile // 128) ** 2 + 16),
                    quant_format=QuantFormat.QDQ, per_channel=True,
                    activation_type=act, weight_type=QuantType.QInt8,
                    extra_options={"ActivationSymmetric": act == QuantType.QInt8})
    return out


def to_fp16(fp32, tile):
    from onnxconverter_common import float16
    m = float16.convert_float_to_float16(onnx.load(fp32), keep_io_types=True)
    out = os.path.join(OUT, f"fp16_t{tile}.onnx")
    onnx.save(m, out)
    return out


def run_tiled(path, rgb, tile):
    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    E.TILE = tile
    up, _ = E.sr_tiled(sess, rgb)
    E.TILE = 128
    return up


def main():
    os.makedirs(OUT, exist_ok=True)
    pages = real_pages()
    print("calib pages", len(pages))
    models = {}
    for tile in (128, 256):
        fp32 = export_anime(tile)
        models[f"fp32_t{tile}"] = (fp32, tile)
        models[f"int8u_t{tile}"] = (quantize(fp32, pages, tile, QuantType.QUInt8, "int8u"), tile)
        models[f"int8s_t{tile}"] = (quantize(fp32, pages, tile, QuantType.QInt8, "int8s"), tile)
        models[f"fp16_t{tile}"] = (to_fp16(fp32, tile), tile)
    for k, (p, _) in models.items():
        print(k, os.path.getsize(p) // 1024, "KB", "opset",
              [o.version for o in onnx.load(p).opset_import if o.domain in ("", "ai.onnx")])

    # 画質: 紙面 2 枚 (楽譜・チラシ) で fp32_t128 との PSNR
    tests = [pages[0], pages[-1]]
    ref = [run_tiled(models["fp32_t128"][0], t, 128) for t in tests]
    for k, (p, tile) in models.items():
        ps = []
        for t, r in zip(tests, ref):
            o = run_tiled(p, t, tile)
            mse = np.mean((o.astype(np.float64) - r.astype(np.float64)) ** 2)
            ps.append(99.0 if mse == 0 else 10 * np.log10(255 ** 2 / mse))
        print(f"{k:12s} PSNR vs fp32_t128: " + " ".join(f"{v:.1f}dB" for v in ps))

    # 小さい文字 (チラシを 40% に縮小 = 紙が小さく写った撮影) の拡大比較
    m = json.load(open(os.path.join(E.ROOT, "training_data/eval_heldout/user_scene.json"),
                       encoding="utf-8"))
    page = E.warp(cv2.imread(os.path.join(E.ROOT, "training_data/eval_heldout/user_scene.jpg")),
                  m["corners"])
    page = cv2.resize(page, None, fx=0.4, fy=0.4, interpolation=cv2.INTER_AREA)
    h, w = page.shape[:2]
    small = cv2.cvtColor(cv2.resize(page, (w // 2, h // 2), interpolation=cv2.INTER_AREA),
                         cv2.COLOR_BGR2RGB)
    y0, x0 = int(h * 0.05), int(w * 0.62)
    cells = [("orig", page)]
    for k in ("fp32_t128", "int8u_t128", "int8s_t128", "fp16_t128", "fp32_t256"):
        p, tile = models[k]
        up = cv2.resize(run_tiled(p, small, tile), (w, h), interpolation=cv2.INTER_AREA)
        cells.append((k, cv2.cvtColor(up, cv2.COLOR_RGB2BGR)))
    crops = []
    for lab, im in cells:
        c = cv2.resize(im[y0:y0 + 160, x0:x0 + 260], None, fx=2, fy=2,
                       interpolation=cv2.INTER_NEAREST).copy()
        cv2.putText(c, lab, (6, 26), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
        crops.append(c)
    cv2.imwrite(os.path.join(OUT, "small_text.png"),
                np.vstack([np.hstack(crops[:3]), np.hstack(crops[3:])]))


if __name__ == "__main__":
    main()
