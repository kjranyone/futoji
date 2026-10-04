# -*- coding: utf-8 -*-
"""imagegen 生成のネガティブ (紙なし) 3 枚を train_real の学習ペアにする。

promote_captures.py の出す形式 (images/ + masks/ + manifest.json) に合わせる。
マスクは全面 0 (= 紙ではない)。docs/datasets/README.md の警告どおり
gen_teacher_masks.py にはかけない (機器を紙として学習してしまう)。
"""

import datetime
import json
import os

import cv2
import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, "training_data", "paper_photos", "images")
DST = os.path.join(ROOT, "training_data", "train_real")

ITEMS = {
    "0210": "PC デスク (ノート PC・ケーブル・USB ハブ・リモコン。紙なし)",
    "0211": "キッチンテーブル (まな板・シリコンマット・タイル。紙なし)",
    "0212": "ソファのタブレット (雑誌風画面は物理的な紙ではない)",
}


def main():
    img_dir = os.path.join(DST, "images")
    mask_dir = os.path.join(DST, "masks")
    os.makedirs(img_dir, exist_ok=True)
    os.makedirs(mask_dir, exist_ok=True)
    manifest_path = os.path.join(DST, "manifest.json")
    manifest = {}
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as fp:
            manifest = json.load(fp)
    for stem, desc in ITEMS.items():
        src = os.path.join(SRC, stem + ".png")
        im = cv2.imread(src, cv2.IMREAD_GRAYSCALE)
        if im is None:
            raise SystemExit(f"画像がない: {src}")
        cv2.imwrite(os.path.join(img_dir, stem + ".jpg"), im,
                    [cv2.IMWRITE_JPEG_QUALITY, 95])
        cv2.imwrite(os.path.join(mask_dir, stem + "_mask.png"),
                    np.zeros(im.shape[:2], np.uint8))
        manifest["imgneg_" + stem] = {
            "source": "imagegen_negative", "src_label": f"paper_photos/images/{stem}.png",
            "edited": False, "negative": True, "note": desc,
            "promoted_at": datetime.datetime.now().isoformat(timespec="seconds"),
        }
    with open(manifest_path, "w", encoding="utf-8") as fp:
        json.dump(manifest, fp, indent=1, ensure_ascii=False)
    print("added:", ", ".join("imgneg_" + s for s in ITEMS))


if __name__ == "__main__":
    main()
