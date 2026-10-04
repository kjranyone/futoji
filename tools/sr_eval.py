# -*- coding: utf-8 -*-
"""AI シャープ化 (Real-ESRGAN realesr-general-x4v3) の画質・速度を PC で評価する。

実写 (training_data/eval_heldout の紙あり) をアプリと同じく台形補正 (長辺 2600px) し、
次の方式を比べる。結果は build/sr/eval/ に部分拡大の比較画像と時間を出す。

  orig    : 補正のみ (現状)
  sr_q    : 1/4 に縮小 → x4 超解像 → 2600 (最速。細部はモデルの復元頼み)
  sr_h    : 1/2 に縮小 → x4 超解像 → 2600 に縮小 (4 倍重いが元の情報を多く使う)

使い方:
  tools/.venv/Scripts/python tools/sr_eval.py --export   # ONNX 書き出し (タイル固定形状)
  tools/.venv/Scripts/python tools/sr_eval.py            # 評価
"""

import argparse
import glob
import json
import os
import time

import cv2
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
SR_DIR = os.path.join(ROOT, "build", "sr")
SAVE_CAP = 2600  # lib/services/image_pipeline.dart の _saveCap
TILE = 128       # ONNX の入力タイル (出力は 512)
PAD = 8          # タイル境界の継ぎ目対策の重なり (入力側)


class SRVGGNetCompact(nn.Module):
    """Real-ESRGAN の SRVGGNetCompact (BSD-3)。realesr-general-x4v3 の構成。"""

    def __init__(self, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        body = [nn.Conv2d(3, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        for _ in range(num_conv):
            body += [nn.Conv2d(num_feat, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        body += [nn.Conv2d(num_feat, 3 * upscale * upscale, 3, 1, 1)]
        self.body = nn.ModuleList(body)
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for m in self.body:
            out = m(out)
        out = self.upsampler(out)
        return out + F.interpolate(x, scale_factor=self.upscale, mode="nearest")


def load_model(name="realesr-general-x4v3"):
    m = SRVGGNetCompact()
    sd = torch.load(os.path.join(SR_DIR, name + ".pth"), map_location="cpu")
    m.load_state_dict(sd.get("params_ema", sd.get("params", sd)))
    return m.eval()


def export(name):
    m = load_model(name)
    out = os.path.join(SR_DIR, f"{name}_t{TILE}.onnx")
    torch.onnx.export(m, torch.zeros(1, 3, TILE, TILE), out, input_names=["input"],
                      output_names=["output"], opset_version=17, do_constant_folding=True,
                      dynamo=False)
    print("exported", out, os.path.getsize(out) // 1024, "KB")
    return out


def warp(img, corners):
    h, w = img.shape[:2]
    q = (np.array(corners, np.float64) * [w, h]).astype(np.float32)
    wt = (np.linalg.norm(q[1] - q[0]) + np.linalg.norm(q[2] - q[3])) / 2
    ht = (np.linalg.norm(q[3] - q[0]) + np.linalg.norm(q[2] - q[1])) / 2
    s = min(1.0, SAVE_CAP / max(wt, ht))
    W, H = int(round(wt * s)), int(round(ht * s))
    M = cv2.getPerspectiveTransform(q, np.float32([[0, 0], [W, 0], [W, H], [0, H]]))
    return cv2.warpPerspective(img, M, (W, H), flags=cv2.INTER_LINEAR)


def sr_tiled(sess, rgb):
    """タイル (TILE + 重なり) ごとに x4。端は反射で埋めて固定形状に合わせる。"""
    h, w = rgb.shape[:2]
    core = TILE - 2 * PAD
    out = np.zeros((h * 4, w * 4, 3), np.float32)
    padded = cv2.copyMakeBorder(rgb, PAD, PAD + core, PAD, PAD + core, cv2.BORDER_REFLECT)
    n = 0
    for y in range(0, h, core):
        for x in range(0, w, core):
            tile = padded[y:y + TILE, x:x + TILE].astype(np.float32) / 255.0
            o = sess.run(None, {"input": tile.transpose(2, 0, 1)[None]})[0][0].transpose(1, 2, 0)
            o = o[PAD * 4:(PAD + core) * 4, PAD * 4:(PAD + core) * 4]
            hh, ww = min(core, h - y) * 4, min(core, w - x) * 4
            out[y * 4:y * 4 + hh, x * 4:x * 4 + ww] = o[:hh, :ww]
            n += 1
    return np.clip(out * 255, 0, 255).astype(np.uint8), n


def resize_long(img, long):
    h, w = img.shape[:2]
    s = long / max(h, w)
    return cv2.resize(img, (int(round(w * s)), int(round(h * s))), interpolation=cv2.INTER_AREA)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", action="store_true")
    ap.add_argument("--name", default="realesr-general-x4v3")
    ap.add_argument("--threads", type=int, default=4, help="ORT のスレッド数 (端末相当に絞る)")
    args = ap.parse_args()
    onnx_path = os.path.join(SR_DIR, f"{args.name}_t{TILE}.onnx")
    if args.export or not os.path.exists(onnx_path):
        export(args.name)
        if args.export:
            return

    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = args.threads
    sess = ort.InferenceSession(onnx_path, so, providers=["CPUExecutionProvider"])
    out_dir = os.path.join(SR_DIR, "eval")
    os.makedirs(out_dir, exist_ok=True)
    rows = []
    for jp in sorted(glob.glob(os.path.join(ROOT, "training_data", "eval_heldout", "*.json"))):
        meta = json.load(open(jp, encoding="utf-8"))
        if not meta.get("corners"):
            continue
        img = cv2.imread(jp[:-5] + ".jpg")
        page = warp(img, meta["corners"])
        rgb = cv2.cvtColor(page, cv2.COLOR_BGR2RGB)
        H, W = page.shape[:2]
        res = {"orig": page}
        times = {}
        for mode, div in (("sr_q", 4), ("sr_h", 2)):
            small = resize_long(rgb, max(H, W) // div)
            t = time.time()
            up, tiles = sr_tiled(sess, small)
            times[mode] = (time.time() - t, tiles)
            res[mode] = cv2.cvtColor(cv2.resize(up, (W, H), interpolation=cv2.INTER_AREA),
                                     cv2.COLOR_RGB2BGR)
        stem = os.path.basename(jp)[:-5]
        # 中央付近の 500x500 を並べた比較 (左から orig / sr_q / sr_h)
        cy, cx = H // 2, W // 2
        crops = [r[cy - 250:cy + 250, cx - 250:cx + 250] for r in res.values()]
        cv2.imwrite(os.path.join(out_dir, f"{stem}_cmp.png"), np.hstack(crops))
        for k, v in res.items():
            cv2.imwrite(os.path.join(out_dir, f"{stem}_{k}.jpg"), v, [cv2.IMWRITE_JPEG_QUALITY, 92])
        rows.append((stem, W, H, times))
        print(f"{stem} {W}x{H} " + " ".join(f"{k}={t:.1f}s/{n}tiles" for k, (t, n) in times.items()),
              flush=True)


if __name__ == "__main__":
    main()
