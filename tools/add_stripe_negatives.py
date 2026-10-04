# -*- coding: utf-8 -*-
"""ストライプ系背景での誤検出対策ネガの直接合成 (train_real へ登録)。

eval で残った偽陽性はどちらも fabric/checker 系の縞背景:
  A) 暗い枠線に囲まれた明るい矩形領域 (紙にしか見えない)
  B) 縞の上の不規則な白ブロブ
これらを意図的に大量生成して「紙ではない」と学習させる。
共有の合成コード (synthetic_variations) は変更しない。
"""

import datetime
import json
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))

from synthetic_variations import camera_effects, procedural_background  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TRAIN_REAL = os.path.join(ROOT, "training_data", "train_real")
N = 240


def scene_a(rng, W, H):
    """縞背景 + 暗い枠線で囲まれた明るい矩形 (額縁・窓枠風)。"""
    img = procedural_background(rng, W, H, kind=str(rng.choice(["fabric", "checker", "tiles"])))
    x0, y0 = rng.integers(W // 8, W // 2), rng.integers(H // 8, H // 2)
    x1 = min(W - 5, x0 + int(rng.integers(W // 4, W // 2)))
    y1 = min(H - 5, y0 + int(rng.integers(H // 4, H // 2)))
    inner = img[y0:y1, x0:x1]
    # 枠の内側: 明るい (紙と同じ明度域) が危険
    bright = rng.uniform(0.75, 0.98, 3).astype(np.float32)
    a = rng.uniform(0.5, 0.95)
    img[y0:y1, x0:x1] = inner * (1 - a) + bright * a
    thick = int(rng.integers(2, 9))
    color = rng.uniform(0.02, 0.35, 3).tolist()
    cv2.rectangle(img, (x0, y0), (x1, y1), color, thick)
    if rng.random() < 0.5:  # 二重枠
        cv2.rectangle(img, (x0 - thick * 2, y0 - thick * 2),
                      (x1 + thick * 2, y1 + thick * 2), color, thick)
    return img


def scene_b(rng, W, H):
    """縞背景 + 不規則な白ブロブ (光沢・ paint しぶき風)。"""
    img = procedural_background(rng, W, H, kind=str(rng.choice(["fabric", "checker", "stone"])))
    layer = np.zeros((H, W), np.float32)
    cx, cy = rng.integers(0, W), rng.integers(0, H)
    for _ in range(int(rng.integers(4, 10))):
        ang = rng.uniform(0, 2 * np.pi)
        r = rng.uniform(0.04, 0.18) * min(W, H)
        px = int(np.clip(cx + np.cos(ang) * r, 0, W - 1))
        py = int(np.clip(cy + np.sin(ang) * r, 0, H - 1))
        cv2.circle(layer, (px, py), int(rng.uniform(3, r / 2)), 1.0, -1)
    layer = cv2.GaussianBlur(layer, (0, 0), rng.uniform(0.5, 2))
    bright = rng.uniform(0.78, 0.98, 3).astype(np.float32)
    a = layer[..., None] * rng.uniform(0.6, 0.95)
    return img * (1 - a) + bright * a


def main():
    rng = np.random.default_rng(4242)
    W = H = 256
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
    for i in range(N):
        maker = scene_a if i % 2 == 0 else scene_b
        img = np.clip(maker(rng, W, H), 0, 1)
        img = camera_effects(rng, img)
        gray = (img @ np.array([0.299, 0.587, 0.114], np.float32))
        gray = np.clip(gray, 0, 1)
        entry = f"stripneg_{i:04d}"
        if entry in manifest:
            continue
        cv2.imwrite(os.path.join(img_dir, entry + ".jpg"),
                    (gray * 255).astype(np.uint8), [cv2.IMWRITE_JPEG_QUALITY, 95])
        cv2.imwrite(os.path.join(mask_dir, entry + "_mask.png"),
                    np.zeros((H, W), np.uint8))
        manifest[entry] = {
            "source": "stripe_negative_synthesis", "negative": True,
            "scene": "frame_bright" if i % 2 == 0 else "bright_blob",
            "promoted_at": datetime.datetime.now().isoformat(timespec="seconds"),
        }
        added += 1
    with open(manifest_path, "w", encoding="utf-8") as fp:
        json.dump(manifest, fp, indent=1, ensure_ascii=False)
    print("added:", added)


if __name__ == "__main__":
    main()
