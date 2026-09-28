# -*- coding: utf-8 -*-
"""四隅ラベルを目視で付けるための補助画像を作る。

  overview: 全体を縮小し、元画像ピクセル座標のグリッド (200px 間隔) を重ねる
  zoom:     指定した 4 点 (元画像 px) の周辺を原寸で切り出し、20px グリッドと座標を重ねる
            (候補点は赤十字)。角の位置を 1〜数 px の精度で読み取るために使う。

使い方:
  python tools/label_zoom.py overview IMG OUT.jpg
  python tools/label_zoom.py zoom IMG OUT.jpg x1 y1 x2 y2 x3 y3 x4 y4 [--half 150]
"""

import argparse

import cv2
import numpy as np


def overview(path, out, width=1400, step=200):
    im = cv2.imread(path)
    h, w = im.shape[:2]
    s = width / w
    v = cv2.resize(im, (width, round(h * s)), interpolation=cv2.INTER_AREA)
    for x in range(0, w, step):
        cv2.line(v, (round(x * s), 0), (round(x * s), v.shape[0]), (0, 255, 255), 1)
        cv2.putText(v, str(x), (round(x * s) + 2, 12), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 255, 255), 1)
    for y in range(0, h, step):
        cv2.line(v, (0, round(y * s)), (v.shape[1], round(y * s)), (0, 255, 255), 1)
        cv2.putText(v, str(y), (2, round(y * s) - 2), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 255, 255), 1)
    cv2.imwrite(out, v)


def zoom(path, out, pts, half=150, scale=2, step=20):
    im = cv2.imread(path)
    h, w = im.shape[:2]
    tiles = []
    for i, (px, py) in enumerate(pts):
        x0, y0 = int(px) - half, int(py) - half
        pad = cv2.copyMakeBorder(im, half, half, half, half, cv2.BORDER_CONSTANT, value=(0, 0, 0))
        crop = pad[y0 + half:y0 + 3 * half, x0 + half:x0 + 3 * half].copy()
        crop = cv2.resize(crop, None, fx=scale, fy=scale, interpolation=cv2.INTER_NEAREST)
        gx = (x0 // step) * step
        while gx <= x0 + 2 * half:
            X = (gx - x0) * scale
            if 0 <= X < crop.shape[1]:
                cv2.line(crop, (X, 0), (X, crop.shape[0]), (0, 200, 255), 1)
                if gx % (step * 5) == 0:
                    cv2.putText(crop, str(gx), (X + 2, 14), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 255), 1)
            gx += step
        gy = (y0 // step) * step
        while gy <= y0 + 2 * half:
            Y = (gy - y0) * scale
            if 0 <= Y < crop.shape[0]:
                cv2.line(crop, (0, Y), (crop.shape[1], Y), (0, 200, 255), 1)
                if gy % (step * 5) == 0:
                    cv2.putText(crop, str(gy), (2, Y - 3), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 255, 255), 1)
            gy += step
        cx, cy = (px - x0) * scale, (py - y0) * scale
        cv2.drawMarker(crop, (int(cx), int(cy)), (0, 0, 255), cv2.MARKER_CROSS, 24, 2)
        cv2.putText(crop, f"#{i} ({px:.0f},{py:.0f})", (4, crop.shape[0] - 8),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2)
        tiles.append(crop)
    top = np.concatenate(tiles[:2], 1)
    bot = np.concatenate(tiles[2:], 1)
    cv2.imwrite(out, np.concatenate([top, bot], 0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["overview", "zoom"])
    ap.add_argument("image")
    ap.add_argument("out")
    ap.add_argument("coords", nargs="*", type=float)
    ap.add_argument("--half", type=int, default=150)
    a = ap.parse_args()
    if a.mode == "overview":
        overview(a.image, a.out)
    else:
        pts = list(zip(a.coords[0::2], a.coords[1::2]))
        assert len(pts) == 4, "4 点 (x y) x 4 を指定"
        zoom(a.image, a.out, pts, half=a.half)


if __name__ == "__main__":
    main()
