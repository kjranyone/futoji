# -*- coding: utf-8 -*-
"""BiRefNet (教師モデル) で紙面マスクを生成し、学習データにするスクリプト。

- 教師: BiRefNet-general-bb_swin_v1_tiny (MIT, ZhengPeng7 配布の ONNX)
- 入力: training_data/paper_photos/images/*.png (200枚)
- 出力: training_data/paper_photos/masks/*.png (0/255 マスク, 元解像度)
        training_data/paper_photos/qa_overlays/*.png (品質確認用オーバーレイ)

使い方:
  python tools/gen_teacher_masks.py --limit 4      # まず数枚だけ確認
  python tools/train_paper_net.py ...              # 別途学習
  python tools/gen_teacher_masks.py --all          # 全 200 枚を生成
"""

import argparse
import os

import numpy as np
import onnxruntime as ort
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
IMAGES_DIR = os.path.join(HERE, "..", "training_data", "paper_photos", "images")
MASKS_DIR = os.path.join(HERE, "..", "training_data", "paper_photos", "masks")
QA_DIR = os.path.join(HERE, "..", "training_data", "paper_photos", "qa_overlays")
TEACHER = os.path.join(HERE, "BiRefNet-general-tiny.onnx")

SIZE = 1024
MEAN = np.array([0.485, 0.456, 0.406], dtype=np.float32)
STD = np.array([0.229, 0.224, 0.225], dtype=np.float32)


def load_teacher():
    sess = ort.InferenceSession(TEACHER, providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0]
    print("teacher input:", inp.name, inp.shape)
    return sess, inp.name


def preprocess(path):
    im = Image.open(path).convert("RGB").resize((SIZE, SIZE), Image.BILINEAR)
    a = np.asarray(im, dtype=np.float32) / 255.0
    a = (a - MEAN) / STD
    return a.transpose(2, 0, 1)[None]  # 1x3x1024x1024


def run_mask(sess, input_name, path):
    orig = Image.open(path).convert("RGB")
    w, h = orig.size
    x = preprocess(path)
    out = sess.run(None, {input_name: x})[0][0, 0]
    # ONNX 出力に sigmoid 済みかどうかで分岐 (0..1 に収まっていれば済み)
    if out.min() < 0 or out.max() > 1:
        out = 1.0 / (1.0 + np.exp(-out))
    mask = np.asarray(
        Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR)
    )
    return mask, orig


def fill_holes(mask):
    """外周から到達できない 0 領域 (穴) を前景化する。"""
    from collections import deque

    h, w = mask.shape
    reach = np.zeros_like(mask, dtype=bool)
    dq = deque()
    for x in range(w):
        for y in (0, h - 1):
            if mask[y, x] == 0 and not reach[y, x]:
                reach[y, x] = True
                dq.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if mask[y, x] == 0 and not reach[y, x]:
                reach[y, x] = True
                dq.append((y, x))
    while dq:
        y, x = dq.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] == 0 and not reach[ny, nx]:
                reach[ny, nx] = True
                dq.append((ny, nx))
    filled = mask.copy()
    filled[(~reach) & (mask == 0)] = 255
    return filled


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0, help="処理枚数の上限 (0=全部)")
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()

    files = sorted(
        f for f in os.listdir(IMAGES_DIR) if f.lower().endswith(".png")
    )
    if not args.all and args.limit:
        files = files[: args.limit]
    os.makedirs(MASKS_DIR, exist_ok=True)
    os.makedirs(QA_DIR, exist_ok=True)

    sess, input_name = load_teacher()
    stats = []
    for i, f in enumerate(files):
        stem = os.path.splitext(f)[0]
        out_mask = os.path.join(MASKS_DIR, stem + "_mask.png")
        if os.path.exists(out_mask):
            continue
        mask, orig = run_mask(sess, input_name, os.path.join(IMAGES_DIR, f))
        mask = fill_holes(mask)
        # 少し閉じる (境界のギザギザを緩和)
        m = (mask > 127).astype(np.uint8)
        try:
            import torch
            import torch.nn.functional as F

            t = torch.from_numpy(m)[None, None].float()
            for _ in range(2):
                t = F.max_pool2d(t, 3, stride=1, padding=1)
            for _ in range(2):
                t = -F.max_pool2d(-t, 3, stride=1, padding=1)
            m = (t[0, 0].numpy() > 0.5).astype(np.uint8)
        except ImportError:
            pass
        mask = (m * 255).astype(np.uint8)
        Image.fromarray(mask).save(out_mask)

        ov = np.asarray(orig).copy()
        ov[mask > 0] = (ov[mask > 0] * 0.45 + np.array([255, 0, 0]) * 0.55).astype(np.uint8)
        qa_w = 384
        qa = Image.fromarray(ov).resize(
            (qa_w, int(qa_w * ov.shape[0] / ov.shape[1])), Image.BILINEAR
        )
        qa.save(os.path.join(QA_DIR, stem + "_qa.png"))

        fill = (mask > 0).mean()
        stats.append((stem, fill))
        print(f"[{i + 1}/{len(files)}] {stem} fill={fill:.2f}", flush=True)

    fills = np.array([s[1] for s in stats]) if stats else np.array([])
    print(f"done: {len(stats)} masks")
    if len(fills):
        print(f"fill: mean={fills.mean():.2f} min={fills.min():.2f} max={fills.max():.2f}")


if __name__ == "__main__":
    main()
