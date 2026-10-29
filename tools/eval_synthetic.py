# -*- coding: utf-8 -*-
"""保存済みの合成データセット (synthetic_diverse_* / synthetic_expanded_*) で
モデルを条件別に評価する。

画像は学習と同じ 256x256 グレー → ONNX 推論 → マスク比較。学習時の
fixed_val_set (シード合成) と違い、人間が点検できる固定データ + 条件別の内訳
が出る。実写での性能は ./dev.ps1 eval を別途使うこと。

指標:
- 紙あり: 検出率 (アプリと同じ面積ゲート 5%〜99% を通った割合) / 平均 IoU
  (ゲート通過分のみ) / 全体平均 IoU (未検出は 0)
- 紙なし: 誤検出率 (面積ゲートを通ってしまった割合)

ネガティブの分割 (学習への漏れ防止):
  各画像の数値 id が奇数 = mine (ハードネガティブ採掘・学習に使ってよい)
                     偶数 = holdout (評価専用。train_real に入れてはいけない)
  --split holdout が公式の誤検出指標。mine_hard_negatives.py は mine 側だけ採る。

使い方:
  python tools/eval_synthetic.py -M assets/models/paper_seg.onnx --split holdout
  python tools/eval_synthetic.py -M <m.onnx> --dump-fp build/fp.json   # FP の id 一覧
"""

import argparse
import glob
import json
import os
import re

import cv2
import numpy as np
import onnxruntime as ort

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
IMG = 256
MIN_AREA, MAX_AREA = 0.05, 0.99  # DocumentDetector.isPlausiblePaperMask と同じ


def id_parity(path):
    """ファイル名の数値 id の偶奇 (奇数=mine, 偶数=holdout)。"""
    m = re.search(r"(\d+)", os.path.basename(path))
    return int(m.group(1)) % 2 if m else 0


def load_pairs(group_dir, split="all"):
    """(画像パス, マスクパス) のリスト。split で偶奇フィルタ。"""
    out = []
    for mp in sorted(glob.glob(os.path.join(group_dir, "masks", "*_mask.png"))):
        if split == "mine" and id_parity(mp) != 1:
            continue
        if split == "holdout" and id_parity(mp) != 0:
            continue
        stem = os.path.basename(mp)[: -len("_mask.png")]
        out.append((os.path.join(group_dir, "images", stem + ".png"), mp))
    return out


def app_effective_detected(pred):
    """アプリの実効ゲート相当で「紙ありと判定される」か。

    ort_ffi.dart の後段 (DocumentDetector.detectLuminance, paperChecks=false) が
    ネットマスクに課す条件を近似:
      - 面積 5%..99% (isPlausiblePaperMask) は呼び出し側で済み
      - 最大連結成分 ≥ 12%
      - 四角形の面積 ≥ 8%、各辺 ≥ 画像長辺の 18% (_isSaneQuad)
    純 Dart 実装との完全一致は保証しない (近似)。生ゲートより厳しい。
    """
    area = pred.mean()
    if not (MIN_AREA <= area <= MAX_AREA):
        return False
    n, lab, stats, _ = cv2.connectedComponentsWithStats(pred.astype(np.uint8), 8)
    if n <= 1:
        return False
    k = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    if stats[k, cv2.CC_STAT_AREA] < pred.size * 0.12:
        return False
    comp = (lab == k).astype(np.uint8)
    contours, _ = cv2.findContours(comp, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return False
    hull = cv2.convexHull(max(contours, key=cv2.contourArea))
    rect = cv2.minAreaRect(hull)
    (cx, cy), (rw, rh), ang = rect
    long = max(pred.shape)
    if min(rw, rh) < 0.18 * long:
        return False
    if cv2.contourArea(hull) < pred.size * 0.08:
        return False
    return True


def eval_group(sess, name, group_dir, limit=0, split="all", collect_fp=False, thresh=0.0):
    """1 グループを評価。limit=0 で全件。[stats, fp_ids] を返す。"""
    pairs = load_pairs(group_dir, split)
    if limit:
        pairs = pairs[:limit]
    pos_iou_det, pos_iou_all, neg_fp, neg_fp_app = [], [], [], []
    fp_ids = []
    for ip, mp in pairs:
        im = cv2.imread(ip, cv2.IMREAD_GRAYSCALE)
        gt = cv2.imread(mp, cv2.IMREAD_GRAYSCALE) > 127
        if im is None or im.shape != (IMG, IMG):
            continue
        x = (im.astype(np.float32) / 255.0)[None, None]
        if sess.get_inputs()[0].shape[1] == 3:
            # 保存合成は灰色なので、RGB のモデルには R=G=B で渡す
            x = np.repeat(x, 3, axis=1)
        out = sess.run(None, {sess.get_inputs()[0].name: x})[0][0, 0]
        pred = out > thresh
        area = pred.mean()
        detected = MIN_AREA <= area <= MAX_AREA
        detected_app = detected and app_effective_detected(pred)
        if gt.any():
            union = (pred | gt).sum()
            iou = (pred & gt).sum() / union if union else 1.0
            pos_iou_all.append(iou if detected else 0.0)
            if detected:
                pos_iou_det.append(iou)
        else:
            neg_fp.append(1.0 if detected else 0.0)
            neg_fp_app.append(1.0 if detected_app else 0.0)
            if detected and collect_fp:
                stem = os.path.splitext(os.path.basename(ip))[0]
                fp_ids.append(f"{name}/{stem}")
    n_pos, n_neg = len(pos_iou_all), len(neg_fp)
    stats = {
        "group": name, "split": split, "n": n_pos + n_neg,
        "pos": n_pos, "neg": n_neg,
        "det": (len(pos_iou_det) / n_pos) if n_pos else None,
        "iou_det": (float(np.mean(pos_iou_det)) if pos_iou_det else None),
        "iou_all": (float(np.mean(pos_iou_all)) if pos_iou_all else None),
        "fp": (float(np.mean(neg_fp)) if neg_fp else None),
        "fp_n": int(sum(neg_fp)),
        "fp_app": (float(np.mean(neg_fp_app)) if neg_fp_app else None),
        "fp_app_n": int(sum(neg_fp_app)),
    }
    return stats, fp_ids


def discover_groups():
    """training_data の synthetic_* ディレクトリから images/masks を持つグループを集める。"""
    groups = []
    for d in sorted(glob.glob(os.path.join(ROOT, "training_data", "synthetic_*"))):
        # negpool は偶数 id も含めて全件 train_real に取り込み済み (評価に使えない)
        if os.path.basename(d).startswith("synthetic_negpool"):
            continue
        if os.path.isdir(os.path.join(d, "images")):
            groups.append((os.path.basename(d), d))
        for sub in sorted(glob.glob(os.path.join(d, "*"))):
            if os.path.isdir(sub) and os.path.isdir(os.path.join(sub, "images")):
                groups.append((f"{os.path.basename(d)}/{os.path.basename(sub)}", sub))
    return groups


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-M", "--models", nargs="+", required=True)
    ap.add_argument("-D", "--dirs", nargs="*", default=[],
                    help="グループディレクトリ (images/ + masks/)。省略時は自動発見")
    ap.add_argument("--limit", type=int, default=0, help="グループごとの評価枚数上限 (0=全件)")
    ap.add_argument("--split", choices=("all", "mine", "holdout"), default="all",
                    help="ネガティブ/画像の偶奇分割。公式指標は holdout")
    ap.add_argument("--dump-fp", default="", help="偽陽性の id 一覧を JSON で書く")
    args = ap.parse_args()

    groups = [(os.path.basename(d.rstrip("/\\")), os.path.abspath(d)) for d in args.dirs]
    if not groups:
        groups = discover_groups()
    if not groups:
        raise SystemExit("評価グループがありません (-D で指定)")

    results = {}
    dump = {}
    for mp in args.models:
        sess = ort.InferenceSession(mp, providers=["CPUExecutionProvider"])
        label = os.path.splitext(os.path.basename(mp))[0]
        rows, fps = [], []
        for name, gd in groups:
            stats, fp = eval_group(sess, name, gd, args.limit, args.split,
                                   collect_fp=bool(args.dump_fp))
            rows.append(stats)
            fps += fp
        results[label] = rows
        if args.dump_fp:
            dump[label] = sorted(fps)

    print(f"{'model':<18} {'group':<40} {'n':>5} {'検出率':>7} {'IoU(検出)':>9} "
          f"{'誤検出(生)':>13} {'誤検出(アプリ相当)':>15}")
    for label, rows in results.items():
        for r in rows:
            det = f"{r['det']*100:6.1f}%" if r["det"] is not None else "      -"
            ioud = f"{r['iou_det']:.4f}" if r["iou_det"] is not None else "      -"
            fp = (f"{r['fp']*100:5.1f}% ({r['fp_n']}/{r['neg']})"
                  if r["fp"] is not None else "-")
            fpa = (f"{r['fp_app']*100:5.1f}% ({r['fp_app_n']}/{r['neg']})"
                   if r.get("fp_app") is not None else "-")
            print(f"{label:<18} {r['group']:<40} {r['n']:>5} {det} {ioud:>9} {fp:>13} {fpa:>15}")
    if args.dump_fp:
        with open(args.dump_fp, "w", encoding="utf-8") as fp2:
            json.dump(dump, fp2, indent=1, ensure_ascii=False)
        print("dumped:", args.dump_fp)


if __name__ == "__main__":
    main()
