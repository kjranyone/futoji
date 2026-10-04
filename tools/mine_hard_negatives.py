# -*- coding: utf-8 -*-
"""ハードネガティブマイニング: 合成セットの「紙なし」でモデルが誤検出した画像を
train_real に空マスクの学習ペアとして登録する。

- 採掘対象は mine 側 (数値 id 奇数) だけ。holdout 側 (偶数) は評価専用で
  絶対に train_real に入れないこと (eval_synthetic.py --split holdout が公式指標)
- 同名ペアが既にあればスキップ (--force で上書き)
- 登録後は train_paper_net_v2.py が --real-pairs-dir で自動混合する

使い方:
  python tools/mine_hard_negatives.py -M build/paper_seg_v6.onnx
  python tools/mine_hard_negatives.py -M <m.onnx> --list   # 確認だけ
"""

import argparse
import datetime
import json
import os

import cv2
import numpy as np

import eval_synthetic

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
TRAIN_REAL = os.path.join(ROOT, "training_data", "train_real")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-M", "--model", required=True)
    ap.add_argument("-D", "--dirs", nargs="*", default=[],
                    help="グループディレクトリ。省略時は自動発見")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--list", action="store_true", help="対象を表示するだけ")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    groups = [(os.path.basename(d.rstrip("/\\")), os.path.abspath(d)) for d in args.dirs]
    if not groups:
        groups = eval_synthetic.discover_groups()

    import onnxruntime as ort
    sess = ort.InferenceSession(args.model, providers=["CPUExecutionProvider"])
    label = os.path.splitext(os.path.basename(args.model))[0]

    img_dir = os.path.join(TRAIN_REAL, "images")
    mask_dir = os.path.join(TRAIN_REAL, "masks")
    manifest_path = os.path.join(TRAIN_REAL, "manifest.json")
    manifest = {}
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as fp:
            manifest = json.load(fp)

    added = skipped = 0
    for name, gd in groups:
        stats, fp_ids = eval_synthetic.eval_group(
            sess, name, gd, args.limit, split="mine", collect_fp=True)
        for fid in fp_ids:
            # fid = "<グループ名>/<stem>"。グループ名自体に / が含まれることが
            # ある (synthetic_expanded_.../negative_heavy) ので右側だけ割る
            gname, stem = fid.rsplit("/", 1)
            src = os.path.join(gd, "images", stem + ".png")
            im = cv2.imread(src, cv2.IMREAD_GRAYSCALE)
            if im is None:
                continue
            entry = f"synneg_{gname.replace('/', '_')}_{stem}".replace("-", "_")
            out_img = os.path.join(img_dir, entry + ".jpg")
            out_mask = os.path.join(mask_dir, entry + "_mask.png")
            if os.path.exists(out_mask) and not args.force:
                skipped += 1
                continue
            if args.list:
                print(f"  対象 {entry}")
                continue
            os.makedirs(img_dir, exist_ok=True)
            os.makedirs(mask_dir, exist_ok=True)
            cv2.imwrite(out_img, im, [cv2.IMWRITE_JPEG_QUALITY, 95])
            cv2.imwrite(out_mask, np.zeros(im.shape[:2], np.uint8))
            manifest[entry] = {
                "source": "hard_negative_mined", "mined_by_model": label,
                "src_group": gname, "negative": True,
                "promoted_at": datetime.datetime.now().isoformat(timespec="seconds"),
            }
            added += 1
    if not args.list:
        with open(manifest_path, "w", encoding="utf-8") as fp:
            json.dump(manifest, fp, indent=1, ensure_ascii=False)
    print(f"採掘 ({label}): 追加 {added} / 既存スキップ {skipped} "
          f"(mine 側のみ。holdout 側は不使用)")


if __name__ == "__main__":
    main()
