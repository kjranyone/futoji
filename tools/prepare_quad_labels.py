# -*- coding: utf-8 -*-
"""教師マスク (BiRefNet) に四角形を当てはめ、四隅ラベルに変換する。

BiRefNet は「目立つ物体」を切り抜くモデルなので、マスクは紙以外を含んだり
縁がギザギザだったりする。紙は四角形なので、最大連結成分に四角形を当てはめ、
マスクとの一致度 (IoU) が低いものは不採用にする。

出力: training_data/paper_photos/quads.json
  { "<stem>": {"quad": [[x,y]*4 (0..1, TL,TR,BR,BL)], "iou": 0.97, "ok": true}, ... }
QA:   training_data/paper_photos/quad_qa.jpg (緑=採用 / 赤=不採用 の一覧)

使い方:
  tools/.venv/Scripts/python tools/prepare_quad_labels.py
"""

import argparse
import json
import os

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "training_data", "paper_photos")


def order_corners(pts):
    """4 点を TL, TR, BR, BL の順に並べる (重心からの角度で時計回り)。"""
    pts = np.asarray(pts, dtype=np.float64)
    c = pts.mean(axis=0)
    ang = np.arctan2(pts[:, 1] - c[1], pts[:, 0] - c[0])
    pts = pts[np.argsort(ang)]  # -pi..pi: 左上から時計回り (y 下向き)
    # x+y が最小の点を TL にする
    start = int(np.argmin(pts.sum(axis=1)))
    return np.roll(pts, -start, axis=0)


def fit_quad(mask):
    """2 値マスクの最大連結成分に四角形を当てはめる。(quad[4,2] px, iou) or (None, 0)。"""
    m = (mask > 127).astype(np.uint8)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(m, 8)
    if n <= 1:
        return None, 0.0
    k = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    comp = (lab == k).astype(np.uint8)
    contours, _ = cv2.findContours(comp, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    cnt = max(contours, key=cv2.contourArea)
    hull = cv2.convexHull(cnt)
    peri = cv2.arcLength(hull, True)
    quad = None
    # 4 点になるまで近似の粗さを上げる
    for eps in np.linspace(0.005, 0.08, 40):
        approx = cv2.approxPolyDP(hull, eps * peri, True)
        if len(approx) == 4:
            quad = approx[:, 0, :].astype(np.float64)
            break
        if len(approx) < 4:
            break
    if quad is None:
        box = cv2.boxPoints(cv2.minAreaRect(cnt))
        quad = box.astype(np.float64)
    quad = order_corners(quad)
    poly = np.zeros_like(comp)
    cv2.fillPoly(poly, [quad.round().astype(np.int32)], 1)
    full = m
    inter = np.logical_and(poly, full).sum()
    union = np.logical_or(poly, full).sum()
    return quad, float(inter / max(union, 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-iou", type=float, default=0.93)
    ap.add_argument("--min-area", type=float, default=0.05, help="画像面積比の下限")
    args = ap.parse_args()

    img_dir = os.path.join(DATA, "images")
    mask_dir = os.path.join(DATA, "masks")
    out = {}
    tiles = []
    for f in sorted(os.listdir(mask_dir)):
        if not f.endswith("_mask.png"):
            continue
        stem = f[: -len("_mask.png")]
        mask = cv2.imread(os.path.join(mask_dir, f), cv2.IMREAD_GRAYSCALE)
        h, w = mask.shape
        quad, iou = fit_quad(mask)
        ok = quad is not None and iou >= args.min_iou
        if quad is not None:
            area = cv2.contourArea(quad.astype(np.float32)) / (w * h)
            ok = ok and area >= args.min_area
        out[stem] = {
            "quad": None if quad is None else [[float(x / w), float(y / h)] for x, y in quad],
            "iou": round(iou, 4),
            "ok": bool(ok),
        }
        im = cv2.imread(os.path.join(img_dir, stem + ".png"))
        if im is not None:
            t = cv2.resize(im, (160, int(160 * h / w)))
            if quad is not None:
                q = (quad * (160 / w)).round().astype(np.int32)
                cv2.polylines(t, [q], True, (60, 220, 40) if ok else (40, 40, 240), 2)
            cv2.putText(t, f"{stem} {iou:.2f}", (3, 12), cv2.FONT_HERSHEY_SIMPLEX, 0.35,
                        (255, 255, 255), 1, cv2.LINE_AA)
            tiles.append(cv2.resize(t, (160, 220)))

    with open(os.path.join(DATA, "quads.json"), "w", encoding="utf-8") as fp:
        json.dump(out, fp, indent=1)
    n_ok = sum(v["ok"] for v in out.values())
    print(f"quads: {len(out)} fitted, {n_ok} ok (min_iou={args.min_iou})")
    bad = sorted((v["iou"], k) for k, v in out.items() if not v["ok"])
    print("rejected:", ", ".join(f"{k}({i:.2f})" for i, k in bad))

    cols = 20
    rows = (len(tiles) + cols - 1) // cols
    sheet = np.zeros((rows * 220, cols * 160, 3), np.uint8)
    for i, t in enumerate(tiles):
        r, c = divmod(i, cols)
        sheet[r * 220:(r + 1) * 220, c * 160:(c + 1) * 160] = t
    cv2.imwrite(os.path.join(DATA, "quad_qa.jpg"), sheet, [cv2.IMWRITE_JPEG_QUALITY, 80])


if __name__ == "__main__":
    main()
