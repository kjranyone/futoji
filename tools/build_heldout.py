# -*- coding: utf-8 -*-
"""学習に未使用の実写評価セットを tools/heldout_labels.json から作る。

出力 (QuadLabel 形式: <id>.jpg + <id>.json):
  training_data/eval_heldout        撮影そのまま (横)
  training_data/eval_heldout_rot90  時計回り 90 度回転 (縦持ち相当)

評価: ./dev.ps1 eval -Data training_data/eval_heldout
      ./dev.ps1 eval -Data training_data/eval_heldout_rot90
注意: ここに入れた画像は学習 (train_paper_net_v2.py の背景素材を含む) に使わないこと。
"""

import json
import os
import shutil

import cv2

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def write(dst, stem, image, corners, src_path=None, source="manual_heldout"):
    os.makedirs(dst, exist_ok=True)
    if src_path:
        shutil.copyfile(src_path, os.path.join(dst, stem + ".jpg"))
    else:
        cv2.imwrite(os.path.join(dst, stem + ".jpg"), image, [cv2.IMWRITE_JPEG_QUALITY, 95])
    h, w = image.shape[:2]
    label = {
        "version": 1, "image": stem + ".jpg", "width": w, "height": h,
        "corners": None if corners is None else [[round(x / w, 5), round(y / h, 5)] for x, y in corners],
        "predicted": None, "edited": True, "source": source, "created_at": None,
    }
    with open(os.path.join(dst, stem + ".json"), "w", encoding="utf-8") as fp:
        json.dump(label, fp, indent=1)


def main():
    with open(os.path.join(HERE, "heldout_labels.json"), encoding="utf-8") as fp:
        labels = json.load(fp)["images"]
    for stem, item in labels.items():
        src = os.path.join(ROOT, item["src"])
        im = cv2.imread(src)
        if im is None:
            print("skip (画像なし):", item["src"])
            continue
        corners = item["corners"]
        write(os.path.join(ROOT, "training_data", "eval_heldout"), stem, im, corners, src_path=src)
        h = im.shape[0]
        rot = cv2.rotate(im, cv2.ROTATE_90_CLOCKWISE)
        # 時計回り 90 度: (x, y) -> (H - 1 - y, x) (ピクセル座標)
        rc = None if corners is None else [[h - 1 - y, x] for x, y in corners]
        write(os.path.join(ROOT, "training_data", "eval_heldout_rot90"), stem, rot, rc,
              source="manual_heldout_rot90")
    print("done:", len(labels))


if __name__ == "__main__":
    main()
