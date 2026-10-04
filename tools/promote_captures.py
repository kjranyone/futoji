# -*- coding: utf-8 -*-
"""アプリで四隅を補正したキャプチャ (QuadLabel) を学習ペアに昇格する。

src (既定 training_data/eval) の <id>.jpg + <id>.json から
dst (既定 training_data/train_real) へ:
  images/<id>.jpg     ワーク画像 (そのままコピー)
  masks/<id>_mask.png 正解四隅を塗りつぶしたマスク (ネガティブは空)

既定では昇格後に src 側の .jpg/.json を削除する (= 移動)。eval/ に残すと
将来の評価が学習データに対して走る「漏れ」になるため (check_dataset.py が検出)。
--keep でコピーだけにする (その場合は漏れに注意)。

昇格の条件:
  - 紙あり (corners != null): 既定は edited=true (ユーザーが四隅を動かした) のみ。
    --include-unedited で無修正の採用も含める (モデルが正解していたという前提)。
  - 紙なし (corners == null): 常に昇格 (空マスク = 「紙ではない」を学習)。

使い方:
  python tools/promote_captures.py                     # eval → train_real (移動)
  python tools/promote_captures.py --include-unedited  # 無修正採用も含める
  python tools/promote_captures.py --list              # 対象を確認するだけ

train_real は train_paper_net_v2.py が --real-pairs-dir で勝手に混ぜる。
docs/DATASET.md も参照。
"""

import argparse
import datetime
import glob
import json
import os
import sys

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")


def load_label(json_path):
    with open(json_path, encoding="utf-8") as fp:
        lab = json.load(fp)
    corners = lab.get("corners")
    if corners is not None:
        if len(corners) != 4 or any(len(c) != 2 for c in corners):
            raise ValueError("corners が 4 点ではない")
        corners = np.asarray(corners, dtype=np.float64)
        if not np.all((corners >= 0) & (corners <= 1)):
            raise ValueError("corners が 0..1 の範囲外")
    return lab, corners


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(ROOT, "training_data", "eval"))
    ap.add_argument("--dst", default=os.path.join(ROOT, "training_data", "train_real"))
    ap.add_argument("--include-unedited", action="store_true",
                    help="edited=false の紙ありラベルも昇格する")
    ap.add_argument("--keep", action="store_true",
                    help="src 側の .jpg/.json を残す (漏れに注意: check_dataset.py が検出)")
    ap.add_argument("--force", action="store_true", help="同名既存ペアを上書き")
    ap.add_argument("--list", action="store_true", help="対象の一覧だけ表示")
    args = ap.parse_args()

    jsons = sorted(glob.glob(os.path.join(args.src, "*.json")))
    if not jsons:
        print(f"ラベルがありません: {args.src} (./dev.ps1 pull で取り込む)")
        sys.exit(1)

    img_dir = os.path.join(args.dst, "images")
    mask_dir = os.path.join(args.dst, "masks")
    manifest_path = os.path.join(args.dst, "manifest.json")
    manifest = {}
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as fp:
            manifest = json.load(fp)

    n_ok = n_neg = n_skip_edit = n_skip_exists = n_err = 0
    for jp in jsons:
        stem = os.path.splitext(os.path.basename(jp))[0]
        try:
            lab, corners = load_label(jp)
        except (ValueError, KeyError, json.JSONDecodeError) as e:
            print(f"  ERR  {stem}: ラベル不正 ({e})")
            n_err += 1
            continue
        img_path = os.path.join(args.src, lab.get("image", stem + ".jpg"))
        im = cv2.imread(img_path, cv2.IMREAD_GRAYSCALE)
        if im is None:
            print(f"  ERR  {stem}: 画像がない ({img_path})")
            n_err += 1
            continue
        h, w = im.shape
        if (lab.get("width"), lab.get("height")) not in ((w, h), (None, None)):
            print(f"  ERR  {stem}: ラベルの {lab['width']}x{lab['height']} が画像 {w}x{h} と不一致")
            n_err += 1
            continue

        negative = corners is None
        if not negative and not lab.get("edited") and not args.include_unedited:
            n_skip_edit += 1
            continue

        out_img = os.path.join(img_dir, stem + ".jpg")
        out_mask = os.path.join(mask_dir, stem + "_mask.png")
        if os.path.exists(out_mask) and not args.force:
            n_skip_exists += 1
            continue
        if args.list:
            tag = "neg" if negative else ("unedited" if not lab.get("edited") else "edited")
            print(f"  対象 {stem}: {tag}")
            n_ok += 0 if negative else 1
            n_neg += 1 if negative else 0
            continue

        os.makedirs(img_dir, exist_ok=True)
        os.makedirs(mask_dir, exist_ok=True)
        mask = np.zeros((h, w), np.uint8)
        if not negative:
            pts = (corners * [w, h]).round().astype(np.int32)
            cv2.fillPoly(mask, [pts], 255)
        cv2.imwrite(out_img, im, [cv2.IMWRITE_JPEG_QUALITY, 95])
        cv2.imwrite(out_mask, mask)
        manifest[stem] = {
            "source": "app_capture", "src_label": os.path.relpath(jp, ROOT),
            "edited": bool(lab.get("edited")), "negative": negative,
            "promoted_at": datetime.datetime.now().isoformat(timespec="seconds"),
        }
        if not args.keep:
            os.remove(img_path)
            os.remove(jp)
        if negative:
            n_neg += 1
        else:
            n_ok += 1

    if not args.list:
        with open(manifest_path, "w", encoding="utf-8") as fp:
            json.dump(manifest, fp, indent=1, ensure_ascii=False)
        print(f"昇格: 紙あり {n_ok} / 紙なし {n_neg} / 既存スキップ {n_skip_exists} / "
              f"要補正スキップ {n_skip_edit} / エラー {n_err} → {args.dst}"
              f"{' (src に残した)' if args.keep else ' (src から移動)'}")
    else:
        print(f"対象: 紙あり {n_ok} / 紙なし {n_neg} / 要補正スキップ {n_skip_edit}")
    if n_err:
        sys.exit(1)


if __name__ == "__main__":
    main()
