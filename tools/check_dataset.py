# -*- coding: utf-8 -*-
"""training_data の整合性チェック。改善サイクルのたびに実行する。

チェック内容:
  - 評価セット (eval*/): jpg+json のペア、QuadLabel スキーマ、四隅が 0..1・
    凸四角形・面積下限、ラベルの width/height が実画像と一致
  - train_real: images/ と masks/ のペア、マスクが画像と同サイズ、値が二値
  - eval_web: SOURCES.md に全 id の出典があるか
  - 漏れ (leakage): 学習側画像と評価側画像が重複していないか (MD5)

使い方: python tools/check_dataset.py   (エラーがあれば exit 1)
"""

import glob
import hashlib
import json
import os
import sys

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
TD = os.path.join(ROOT, "training_data")

EVAL_DIRS = ["eval", "eval_heldout", "eval_heldout_rot90", "eval_hard", "eval_web"]
TRAIN_DIRS = ["paper_photos/images", "real_captures", "train_real/images"]

MIN_QUAD_AREA = 0.005  # 正規化座標系での四隅四角形の面積下限 (eval_web に紙 1% の難例あり)
# eval_hard は紙がフレームからはみ出す難例を含み、corners は 0..1 を (わずかに) 超え得る。
COORD_LIMIT = 0.5  # これを超えた外側はデータ破損扱い


def quad_area(c):
    a = 0.0
    for i in range(4):
        x1, y1 = c[i]
        x2, y2 = c[(i + 1) % 4]
        a += x1 * y2 - x2 * y1
    return abs(a) / 2


def is_convex(c):
    sign = 0
    for i in range(4):
        (ax, ay), (bx, by), (cx, cy) = c[i], c[(i + 1) % 4], c[(i + 2) % 4]
        cross = (bx - ax) * (cy - by) - (by - ay) * (cx - bx)
        s = 1 if cross > 0 else (-1 if cross < 0 else 0)
        if s != 0:
            if sign == 0:
                sign = s
            elif s != sign:
                return False
    return True


def check_eval_dir(name):
    errors, n_pos, n_neg = [], 0, 0
    d = os.path.join(TD, name)
    jsons = sorted(glob.glob(os.path.join(d, "*.json")))
    jpgs = {os.path.splitext(os.path.basename(p))[0]
            for p in glob.glob(os.path.join(d, "*.jpg"))}
    if not jsons:
        return [f"{name}: ラベル (.json) が 1 件もない"], 0, 0
    seen = set()
    for jp in jsons:
        stem = os.path.splitext(os.path.basename(jp))[0]
        seen.add(stem)
        try:
            with open(jp, encoding="utf-8") as fp:
                lab = json.load(fp)
        except (OSError, json.JSONDecodeError) as e:
            errors.append(f"{name}/{stem}: JSON 読み込み失敗 ({e})")
            continue
        for key in ("image", "width", "height", "corners"):
            if key not in lab:
                errors.append(f"{name}/{stem}: キー '{key}' がない")
        if lab.get("image") != stem + ".jpg":
            errors.append(f"{name}/{stem}: image フィールドが {lab.get('image')!r}")
        corners = lab.get("corners")
        if corners is None:
            n_neg += 1
        else:
            n_pos += 1
            try:
                c = np.asarray(corners, dtype=np.float64)
            except (TypeError, ValueError):
                errors.append(f"{name}/{stem}: corners が数値ではない")
                continue
            if c.shape != (4, 2) or not np.all(np.isfinite(c)) \
                    or not np.all((c >= -COORD_LIMIT) & (c <= 1 + COORD_LIMIT)):
                errors.append(f"{name}/{stem}: corners が 4 点の "
                              f"[-{COORD_LIMIT}, 1+{COORD_LIMIT}] 範囲外")
                continue
            if not is_convex(c.tolist()):
                errors.append(f"{name}/{stem}: corners が凹四角形")
            if quad_area(c.tolist()) < MIN_QUAD_AREA:
                errors.append(f"{name}/{stem}: 四角形の面積が小さすぎ "
                              f"({quad_area(c.tolist()):.3f} < {MIN_QUAD_AREA})")
        img = cv2.imread(os.path.join(d, stem + ".jpg"), cv2.IMREAD_GRAYSCALE)
        if img is None:
            errors.append(f"{name}/{stem}: 画像がない")
        elif (lab.get("width"), lab.get("height")) != img.shape[::-1]:
            errors.append(f"{name}/{stem}: ラベル {lab.get('width')}x{lab.get('height')} が"
                          f" 画像 {img.shape[1]}x{img.shape[0]} と不一致")
    for stem in jpgs - seen:
        errors.append(f"{name}/{stem}: .json がない (.jpg だけある)")
    return errors, n_pos, n_neg


def check_train_real():
    errors = []
    base = os.path.join(TD, "train_real")
    if not os.path.isdir(base):
        return errors
    masks = sorted(glob.glob(os.path.join(base, "masks", "*_mask.png")))
    images = {os.path.splitext(os.path.basename(p))[0]
              for p in glob.glob(os.path.join(base, "images", "*.jpg"))}
    for mp in masks:
        stem = os.path.basename(mp)[: -len("_mask.png")]
        if stem not in images:
            errors.append(f"train_real/{stem}: images/ に .jpg がない")
            continue
        mk = cv2.imread(mp, cv2.IMREAD_GRAYSCALE)
        im = cv2.imread(os.path.join(base, "images", stem + ".jpg"), cv2.IMREAD_GRAYSCALE)
        if mk is None or im is None:
            errors.append(f"train_real/{stem}: 読み込み失敗")
            continue
        if mk.shape != im.shape:
            errors.append(f"train_real/{stem}: マスク {mk.shape} が画像 {im.shape} と不一致")
        vals = np.unique(mk)
        if not np.all((vals == 0) | (vals == 255)):
            errors.append(f"train_real/{stem}: マスクが二値ではない (値 {vals[:5]})")
    for stem in images - {os.path.basename(m)[:-len("_mask.png")] for m in masks}:
        errors.append(f"train_real/{stem}: masks/ に _mask.png がない")
    return errors


def check_sources():
    errors = []
    web = os.path.join(TD, "eval_web")
    src = os.path.join(web, "SOURCES.md")
    if not os.path.isdir(web):
        return errors
    if not os.path.exists(src):
        return ["eval_web/SOURCES.md がない (出典・ライセンスの記録必須)"]
    text = open(src, encoding="utf-8").read()
    for jp in glob.glob(os.path.join(web, "*.json")):
        stem = os.path.splitext(os.path.basename(jp))[0]
        if stem not in text:
            errors.append(f"eval_web/{stem}: SOURCES.md に出典がない")
    return errors


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as fp:
        for chunk in iter(lambda: fp.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_leakage():
    """同じ画像が学習側と評価側の両方に無いか (バイト列の完全一致で判定)。"""
    errors = []
    train_hashes = {}
    for sub in TRAIN_DIRS:
        for p in glob.glob(os.path.join(TD, sub, "*")):
            if os.path.isfile(p) and not p.endswith(".json"):
                train_hashes[md5(p)] = p
    for name in EVAL_DIRS:
        for p in glob.glob(os.path.join(TD, name, "*.jpg")):
            h = md5(p)
            if h in train_hashes:
                errors.append(f"漏れ: {os.path.relpath(p, TD)} が学習側 "
                              f"{os.path.relpath(train_hashes[h], TD)} と重複")
    return errors


def main():
    all_errors = []
    print(f"{'データセット':<22} {'紙あり':>6} {'紙なし':>6}  結果")
    for name in EVAL_DIRS:
        d = os.path.join(TD, name)
        if not os.path.isdir(d):
            if name == "eval":
                print(f"{name:<22} {'-':>6} {'-':>6}  未作成 (pull で作られる)")
            else:
                all_errors.append(f"{name}: ディレクトリがない")
            continue
        errors, n_pos, n_neg = check_eval_dir(name)
        all_errors += errors
        print(f"{name:<22} {n_pos:>6} {n_neg:>6}  {'OK' if not errors else f'NG ({len(errors)})'}")
    for label, errors in (("train_real", check_train_real()), ("eval_web 出典", check_sources()),
                          ("漏れ (学習×評価)", check_leakage())):
        if errors:
            all_errors += errors
            print(f"{label:<22} {'':>6} {'':>6}  NG ({len(errors)})")
        else:
            print(f"{label:<22} {'':>6} {'':>6}  OK")
    if all_errors:
        print("\n--- エラー ---")
        for e in all_errors:
            print(" ", e)
        sys.exit(1)
    print("\n全チェック OK")


if __name__ == "__main__":
    main()
