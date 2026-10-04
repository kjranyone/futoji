# -*- coding: utf-8 -*-
"""生成したネガポール (synthetic_negpool*) の「紙なし」だけを train_real に登録する。

これらは学習専用の新規画像 (評価セットとは無関係) なので偶奇分割は不要。
既存の positive は on-the-fly 合成と重複するため入れない。

使い方: python tools/add_negative_pool.py [--pool training_data/synthetic_negpool_2026-10-02]
"""

import argparse
import datetime
import glob
import json
import os

import cv2
import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TRAIN_REAL = os.path.join(ROOT, "training_data", "train_real")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool", default=os.path.join(
        ROOT, "training_data", "synthetic_negpool_2026-10-02"))
    args = ap.parse_args()
    pool = args.pool
    pool_name = os.path.basename(pool)
    img_dir = os.path.join(TRAIN_REAL, "images")
    mask_dir = os.path.join(TRAIN_REAL, "masks")
    os.makedirs(img_dir, exist_ok=True)
    os.makedirs(mask_dir, exist_ok=True)
    manifest_path = os.path.join(TRAIN_REAL, "manifest.json")
    manifest = {}
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as fp:
            manifest = json.load(fp)
    added = 0
    for mp in sorted(glob.glob(os.path.join(pool, "masks", "*_mask.png"))):
        mk = cv2.imread(mp, cv2.IMREAD_GRAYSCALE)
        if mk is None or mk.any():
            continue  # 紙なしのみ
        stem = os.path.basename(mp)[: -len("_mask.png")]
        entry = f"negpool_{pool_name}_{stem}"
        if entry in manifest:
            continue
        im = cv2.imread(os.path.join(pool, "images", stem + ".png"), cv2.IMREAD_GRAYSCALE)
        if im is None:
            continue
        cv2.imwrite(os.path.join(img_dir, entry + ".jpg"), im,
                    [cv2.IMWRITE_JPEG_QUALITY, 95])
        cv2.imwrite(os.path.join(mask_dir, entry + "_mask.png"),
                    np.zeros(im.shape[:2], np.uint8))
        manifest[entry] = {
            "source": "synthetic_negative_pool", "negative": True,
            "src": f"{pool_name}/{stem}",
            "promoted_at": datetime.datetime.now().isoformat(timespec="seconds"),
        }
        added += 1
    with open(manifest_path, "w", encoding="utf-8") as fp:
        json.dump(manifest, fp, indent=1, ensure_ascii=False)
    print("added:", added)


if __name__ == "__main__":
    main()
