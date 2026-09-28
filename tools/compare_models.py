# -*- coding: utf-8 -*-
"""学習に使っていない実写で、複数の紙面モデルのマスクを並べて目視比較する。

前処理はアプリの切り抜き画面に合わせる (長辺 1000px → 輝度 → 256x256 に縦横比無視で縮小)。
各モデルについて マスク (半透明) と 四角形 を描く。

注意: ここの四角形は OpenCV で当てはめた近似で、アプリの後処理
(DocumentDetector.detectLuminance) とは別物。数値評価には使わないこと。
四隅の精度はアプリと同一経路の評価ハーネスで測る:
  ./dev.ps1 eval -Data training_data/eval_heldout            (PC)
  ./dev.ps1 selftest                                          (実機)

使い方:
  tools/.venv/Scripts/python tools/compare_models.py \
      --models assets/models/paper_seg.onnx build/paper_seg_v2.onnx
出力: build/compare/<image>.jpg と build/compare/sheet.jpg
"""

import argparse
import glob
import os

import cv2
import numpy as np
import onnxruntime as ort

from prepare_quad_labels import fit_quad
from train_paper_net_v2 import REAL_BG

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def default_images():
    real = sorted(glob.glob(os.path.join(ROOT, "training_data", "real_captures", "*.jpg")))
    held = [p for p in real if os.path.splitext(os.path.basename(p))[0] not in REAL_BG]
    extra = [os.path.join(HERE, n) for n in ("user_scene.jpg", "upright_scene.jpg", "fail_upright.jpg")]
    return held + [p for p in extra if os.path.exists(p)]


def app_input(bgr):
    h, w = bgr.shape[:2]
    s = 1000 / max(h, w)
    if s < 1:
        bgr = cv2.resize(bgr, (round(w * s), round(h * s)), interpolation=cv2.INTER_AREA)
    b, g, r = [c.astype(np.float32) for c in cv2.split(bgr)]
    gray = (r * 0.299 + g * 0.587 + b * 0.114)
    x = cv2.resize(gray, (256, 256), interpolation=cv2.INTER_LINEAR) / 255.0
    return bgr, x.astype(np.float32)


def run(sess, x):
    out = sess.run(None, {sess.get_inputs()[0].name: x[None, None]})[0][0, 0]
    return (out > 0).astype(np.uint8) * 255


def panel(work, mask256, title):
    h, w = work.shape[:2]
    m = cv2.resize(mask256, (w, h), interpolation=cv2.INTER_NEAREST)
    ov = work.copy()
    ov[m > 0] = (ov[m > 0] * 0.5 + np.array([40, 200, 255]) * 0.5).astype(np.uint8)
    fill = (mask256 > 0).mean()
    if 0.02 <= fill <= 0.99:
        quad, _ = fit_quad(m)
        if quad is not None:
            cv2.polylines(ov, [quad.round().astype(np.int32)], True, (40, 40, 240), 3)
    else:
        title += " (no paper)"
    cv2.putText(ov, title, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 0), 4, cv2.LINE_AA)
    cv2.putText(ov, title, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (255, 255, 255), 2, cv2.LINE_AA)
    return ov


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="+", required=True)
    ap.add_argument("--images", nargs="*")
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "compare"))
    ap.add_argument("--rot90", action="store_true", help="縦持ち相当に 90 度回転した入力も比較する")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    sessions = [(os.path.basename(m), ort.InferenceSession(m, providers=["CPUExecutionProvider"]))
                for m in args.models]
    rows = []
    for path in args.images or default_images():
        src = cv2.imread(path, cv2.IMREAD_COLOR)
        variants = [("", src)]
        if args.rot90:
            variants.append((" rot90", cv2.rotate(src, cv2.ROTATE_90_CLOCKWISE)))
        for tag, im in variants:
            work, x = app_input(im)
            panels = [panel(work, run(s, x), name) for name, s in sessions]
            row = np.concatenate(panels, axis=1)
            name = os.path.splitext(os.path.basename(path))[0] + tag.replace(" ", "_")
            cv2.imwrite(os.path.join(args.out, name + ".jpg"), row, [cv2.IMWRITE_JPEG_QUALITY, 80])
            th = 240
            rows.append(cv2.resize(row, (round(row.shape[1] * th / row.shape[0]), th)))
    width = max(r.shape[1] for r in rows)
    rows = [np.pad(r, ((0, 0), (0, width - r.shape[1]), (0, 0))) for r in rows]
    cols = 2
    grid_rows = [np.concatenate(rows[i:i + cols] + [np.zeros_like(rows[0])] * (cols - len(rows[i:i + cols])), 1)
                 for i in range(0, len(rows), cols)]
    sheet = np.concatenate(grid_rows, 0)
    cv2.imwrite(os.path.join(args.out, "sheet.jpg"), sheet, [cv2.IMWRITE_JPEG_QUALITY, 80])
    print("wrote", os.path.join(args.out, "sheet.jpg"), f"({len(rows)} rows)")


if __name__ == "__main__":
    main()
