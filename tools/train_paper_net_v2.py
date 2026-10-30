# -*- coding: utf-8 -*-
"""紙面セグメンテーション v2: 貼り付け合成 + 事前学習済み MobileNetV3 エンコーダ。

v1 (train_paper_net.py) からの変更点:
- 教師マスクは BiRefNet の生マスクではなく、四角形を当てはめた「四隅ラベル」
  (tools/prepare_quad_labels.py の quads.json, ok=true のみ) から作る
- 紙 (生成写真から四隅で切り出し) を、実写の散らかった机など別の背景へ
  ランダムな大きさ・位置・回転・射影で貼り付けて学習データを作る
- アプリの前処理 (4:3 / 16:9 のフレームを 256x256 へ縦横比無視で縮小、
  センサー向きのままの 90 度回転) を再現する
- diverse (既定) は柄付き背景・手続き紙面・小物遮蔽・撮影劣化を追加。
  --synth-profile legacy で従来条件。比較用の固定検証セットは従来条件を維持する
- --synth-sets で保存済みの合成セット (export_synthetic の出力) をバッチに混合する。
  数値 id が奇数のペアだけを読み、偶数 (holdout) は eval_synthetic.py の評価専用に残す
- エンコーダは ImageNet 事前学習済み MobileNetV3-Small (BSD-3)。
  入出力はアプリと同じ 1x1x256x256 (グレー 0..1 → ロジット) のまま
- --color で入力を 1x3x256x256 (RGB 0..1) にする。白い紙とベージュの机のように
  明るさが近く色味だけが違う場面を見分けるため。全体の色温度のずれと、明るさが紙に
  近い暖色の机も合成する。保存合成・train_real (灰色) は R=G=B として混ぜる
- --p-fold / --p-corner-object / --p-same: 角の折り返し・めくれ、角を覆うスマホ・カップ・手、
  同じ紙 (同じ色) の重なり。正解はどれも一番上の紙全体の四角形 (隠れた角・欠けた角を含む)
- --color-pairs で色付きの学習ペア (training_data/train_hard_gen: 生成難例に四隅を手で付けた
  もの) を RGB のまま混ぜる。評価用の eval_hard_gen は混ぜない

使い方:
  tools/.venv/Scripts/python tools/train_paper_net_v2.py --steps 4000
  tools/.venv/Scripts/python tools/train_paper_net_v2.py --preview 24   # 合成サンプルの確認だけ
  tools/.venv/Scripts/python tools/train_paper_net_v2.py --export-synth 256 --synth-out training_data/synthetic_diverse
"""

import argparse
import json
import math
import os
import time

import cv2
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, IterableDataset, get_worker_info

from synthetic_variations import (PROFILE_DEFAULTS, camera_effects, corner_object, fold_corner,
                                  object_occluder, procedural_background, procedural_paper)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
PAPER_DIR = os.path.join(ROOT, "training_data", "paper_photos")
REAL_DIR = os.path.join(ROOT, "training_data", "real_captures")
REAL_PAIRS_DIR = os.path.join(ROOT, "training_data", "train_real")
COLOR_PAIRS_DIRS = [os.path.join(ROOT, "training_data", "train_hard_gen")]
# 保存済み合成セット (docs/datasets/README.md)。奇数 id だけを学習に使う
SAVED_SYNTH_DIRS = [
    os.path.join(ROOT, "training_data", "synthetic_diverse_2026-10-02"),
    *(os.path.join(ROOT, "training_data", "synthetic_expanded_2026-10-02", g)
      for g in ("ordinary", "printed_layouts", "overlap_occlusion", "clipped_pages",
                "negative_heavy")),
]
IMG = 256
CANVAS_LONG = 384
SRC_LONG = 1024  # 素材画像を読み込むときの長辺 (メモリと速度のため縮小)

# 背景に使う実写 (教師マスク = 避ける領域)。ウェブカメラのみの 1 枚は全面を背景に使う。
REAL_BG = {
    "CAP2807639686690776350": "avoid",
    "CAP3333354730965744561": "avoid",
    "CAP3559555545420765940": "avoid",
    "CAP662583892609222133": "avoid",
    "CAP6803204912898649751": "avoid",
    "CAP7457501899405073292": "all",
}


# ---------------------------------------------------------------- 素材

def _resize_long(im, long):
    h, w = im.shape[:2]
    s = long / max(h, w)
    if s >= 1:
        return im, 1.0
    return cv2.resize(im, (round(w * s), round(h * s)), interpolation=cv2.INTER_AREA), s


def order_corners(pts):
    pts = np.asarray(pts, dtype=np.float64)
    c = pts.mean(axis=0)
    ang = np.arctan2(pts[:, 1] - c[1], pts[:, 0] - c[0])
    pts = pts[np.argsort(ang)]
    start = int(np.argmin(pts.sum(axis=1)))
    return np.roll(pts, -start, axis=0)


def load_assets(val_frac=0.15, seed=7):
    """紙素材 (画像 + 四隅 px) と背景素材 (画像 + 避ける領域マスク) を読み込む。"""
    with open(os.path.join(PAPER_DIR, "quads.json"), encoding="utf-8") as fp:
        quads = json.load(fp)
    stems = sorted(k for k, v in quads.items() if v["ok"])
    rng = np.random.default_rng(seed)
    order = rng.permutation(len(stems))
    n_val = max(1, int(len(stems) * val_frac))
    val_stems = {stems[i] for i in order[:n_val]}

    papers = {"train": [], "val": []}
    bgs = []
    for s in stems:
        im = cv2.imread(os.path.join(PAPER_DIR, "images", s + ".png"), cv2.IMREAD_COLOR)
        im, _ = _resize_long(im, SRC_LONG)
        h, w = im.shape[:2]
        q = np.array(quads[s]["quad"], dtype=np.float64) * [w, h]
        papers["val" if s in val_stems else "train"].append((s, im, q))
        if s not in val_stems:
            avoid = np.zeros((h, w), np.uint8)
            cv2.fillPoly(avoid, [q.round().astype(np.int32)], 1)
            avoid = cv2.dilate(avoid, np.ones((25, 25), np.uint8))
            bgs.append((s, im, avoid))
    for s, mode in REAL_BG.items():
        im = cv2.imread(os.path.join(REAL_DIR, s + ".jpg"), cv2.IMREAD_COLOR)
        im, _ = _resize_long(im, SRC_LONG)
        h, w = im.shape[:2]
        if mode == "all":
            avoid = np.zeros((h, w), np.uint8)
        else:
            m = cv2.imread(os.path.join(REAL_DIR, "masks", s + "_mask.png"), cv2.IMREAD_GRAYSCALE)
            m = cv2.resize(m, (w, h), interpolation=cv2.INTER_NEAREST)
            avoid = cv2.dilate((m > 127).astype(np.uint8), np.ones((31, 31), np.uint8))
        # 実写背景は数が少ないので重みを上げる (リストに複数回入れる)
        for _ in range(12):
            bgs.append((s, im, avoid))
    return papers, bgs


# ---------------------------------------------------------------- 合成

def rand_canvas(rng):
    aspect = rng.choice([4 / 3, 3 / 4, 16 / 9, 9 / 16, 1.0], p=[0.3, 0.3, 0.15, 0.15, 0.1])
    if aspect >= 1:
        return CANVAS_LONG, round(CANVAS_LONG / aspect)
    return round(CANVAS_LONG * aspect), CANVAS_LONG


def procedural_bg(rng, W, H):
    """机っぽい手続き背景 (木目風の縞 + 物体の矩形 + 照明ムラ)。"""
    base = rng.uniform(0.08, 0.85, 3)
    img = np.ones((H, W, 3), np.float32) * base
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    ang = rng.uniform(0, np.pi)
    stripes = np.sin((np.cos(ang) * xx + np.sin(ang) * yy) / rng.uniform(3, 20) + rng.uniform(0, 6))
    img += (stripes[..., None] * rng.uniform(0, 0.06))
    for _ in range(int(rng.integers(0, 6))):
        w, h = int(rng.integers(10, W // 2)), int(rng.integers(10, H // 2))
        x0, y0 = int(rng.integers(0, W - w)), int(rng.integers(0, H - h))
        color = rng.uniform(0, 1, 3)
        if rng.random() < 0.3:
            color = np.full(3, rng.uniform(0.85, 1.0))  # 白い物 (紙と紛らわしい)
        cv2.rectangle(img, (x0, y0), (x0 + w, y0 + h), color.tolist(), -1)
    return np.clip(img, 0, 1)


def crop_bg(rng, bgs, W, H, tries=25):
    """避ける領域をほぼ含まない背景切り抜き (float 0..1, BGR)。見つからなければ None。"""
    if not bgs:
        return None
    for _ in range(tries):
        _, im, avoid = bgs[int(rng.integers(len(bgs)))]
        h, w = im.shape[:2]
        aspect = W / H
        max_cw = min(w, h * aspect)
        cw = max_cw * rng.uniform(0.2, 1.0)
        ch = cw / aspect
        if cw < 32 or ch < 32:
            continue
        x0 = rng.uniform(0, w - cw)
        y0 = rng.uniform(0, h - ch)
        xi, yi, xw, yh = int(x0), int(y0), int(cw), int(ch)
        if avoid[yi:yi + yh, xi:xi + xw].mean() > 0.003:
            continue
        crop = im[yi:yi + yh, xi:xi + xw]
        if rng.random() < 0.5:
            crop = crop[:, ::-1]
        return cv2.resize(crop, (W, H), interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0
    return None


def target_quad(rng, W, H, src_q, allow_out, area=None, center=None):
    """貼り付け先の四隅 (px, TL,TR,BR,BL)。"""
    top = np.linalg.norm(src_q[1] - src_q[0]) + np.linalg.norm(src_q[2] - src_q[3])
    side = np.linalg.norm(src_q[3] - src_q[0]) + np.linalg.norm(src_q[2] - src_q[1])
    aspect = side / max(top, 1e-6)  # 高さ/幅
    area = (area if area is not None else rng.uniform(0.04, 0.7)) * W * H
    pw = math.sqrt(area / aspect)
    ph = pw * aspect
    theta = rng.uniform(-np.pi, np.pi) if rng.random() < 0.35 else rng.normal(0, 0.25)
    rect = np.array([[-pw / 2, -ph / 2], [pw / 2, -ph / 2], [pw / 2, ph / 2], [-pw / 2, ph / 2]])
    rot = np.array([[math.cos(theta), -math.sin(theta)], [math.sin(theta), math.cos(theta)]])
    q = rect @ rot.T
    q += rng.normal(0, 0.05 * min(pw, ph), q.shape)  # 射影 (カメラの傾き) っぽい歪み
    ext = q.max(axis=0) - q.min(axis=0)
    if center is not None:
        cx, cy = center
    elif allow_out:
        cx, cy = rng.uniform(0.15, 0.85) * W, rng.uniform(0.15, 0.85) * H
    else:
        mx = max(0.0, (W - ext[0]) / 2 - 2)
        my = max(0.0, (H - ext[1]) / 2 - 2)
        cx = W / 2 + rng.uniform(-mx, mx)
        cy = H / 2 + rng.uniform(-my, my)
    return q + [cx, cy]


def paste_paper(rng, canvas, paper, allow_out, area=None, center=None, p_panel=0.0, p_fold=0.0):
    """紙を canvas に貼り、(canvas, mask(0/1 float), dst_quad) を返す。

    p_fold の確率で角を 1 つ折り返す/めくる (fold_corner)。mask は紙全体の四角形のまま。"""
    H, W = canvas.shape[:2]
    _, im, src_q = paper
    dst = target_quad(rng, W, H, src_q, allow_out, area=area, center=center)
    # 始点をずらして「紙の向き」もランダムにする (180 度回転した紙など)
    k = int(rng.integers(4)) if rng.random() < 0.3 else 0
    src = np.roll(src_q, k, axis=0).astype(np.float32)
    M = cv2.getPerspectiveTransform(src, dst.astype(np.float32))
    warped = cv2.warpPerspective(im, M, (W, H), flags=cv2.INTER_LINEAR,
                                 borderMode=cv2.BORDER_REFLECT).astype(np.float32) / 255.0
    # アンチエイリアスした alpha (4 倍で塗って縮小)
    ss = 4
    big = np.zeros((H * ss, W * ss), np.uint8)
    cv2.fillPoly(big, [(dst * ss).round().astype(np.int32)], 255)
    alpha = cv2.resize(big, (W, H), interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0
    # 紙の影 (少しずらしてぼかした alpha で背景を暗くする)
    if rng.random() < 0.7:
        sh = np.roll(alpha, (int(rng.integers(-4, 5)), int(rng.integers(-4, 5))), axis=(0, 1))
        sh = cv2.GaussianBlur(sh, (0, 0), rng.uniform(1.5, 6))
        canvas = canvas * (1 - sh[..., None] * rng.uniform(0.1, 0.45))
    # 紙の内側の色ブロック (見出しの帯・色付きの枠・写真など)。影を付けず、正解は
    # 紙全体のまま。v3 は重なり学習の副作用で「紙の中の大きな色の変化」を別の紙の
    # 境目と誤認し、色付きのチラシを分割した (eval_heldout_rot90 の fail_upright)。
    if rng.random() < p_panel:
        unit = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32)
        Mu = cv2.getPerspectiveTransform(unit, dst.astype(np.float32))
        for _ in range(int(rng.integers(1, 4))):
            if rng.random() < 0.5:  # 横いっぱいの帯
                y0 = rng.uniform(0.0, 0.8)
                rect = [0.02, y0, 0.98, min(0.98, y0 + rng.uniform(0.08, 0.45))]
            else:
                x0, y0 = rng.uniform(0.02, 0.7), rng.uniform(0.02, 0.7)
                rect = [x0, y0, min(0.98, x0 + rng.uniform(0.1, 0.5)),
                        min(0.98, y0 + rng.uniform(0.1, 0.5))]
            pts = np.array([[rect[0], rect[1]], [rect[2], rect[1]], [rect[2], rect[3]],
                            [rect[0], rect[3]]], np.float32)[None]
            poly = cv2.perspectiveTransform(pts, Mu)[0]
            color = rng.uniform(0, 1, 3) if rng.random() < 0.7 else np.full(3, rng.uniform(0.05, 0.5))
            layer = np.zeros((H, W), np.float32)
            cv2.fillPoly(layer, [poly.round().astype(np.int32)], 1.0)
            a = layer * rng.uniform(0.5, 0.95)
            warped = warped * (1 - a[..., None]) + color[None, None, :] * a[..., None]
    # 紙自体の明るさ・色味 (照明の違い)
    warped = warped * rng.uniform(0.75, 1.15) * rng.uniform(0.93, 1.07, 3)
    if p_fold > 0 and rng.random() < p_fold:
        return fold_corner(rng, canvas, warped, alpha, dst), alpha, dst
    canvas = canvas * (1 - alpha[..., None]) + warped * alpha[..., None]
    return canvas, alpha, dst


def photometric(rng, img):
    """照明・カメラ劣化 (float BGR 0..1)。"""
    H, W = img.shape[:2]
    img = img * rng.uniform(0.6, 1.3)
    img = np.clip(img, 0, 1) ** rng.uniform(0.7, 1.4)
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    ang = rng.uniform(0, 2 * np.pi)
    ramp = (np.cos(ang) * xx / W + np.sin(ang) * yy / H)
    img = img * (1 + (ramp - ramp.mean())[..., None] * rng.uniform(-0.6, 0.6))
    if rng.random() < 0.35:
        # 手や物の影 (ぼかした多角形)
        pts = np.stack([rng.uniform(-0.2, 1.2, 5) * W, rng.uniform(-0.2, 1.2, 5) * H], 1)
        sh = np.zeros((H, W), np.float32)
        cv2.fillPoly(sh, [cv2.convexHull(pts.astype(np.int32))], 1.0)
        sh = cv2.GaussianBlur(sh, (0, 0), rng.uniform(3, 20))
        img = img * (1 - sh[..., None] * rng.uniform(0.15, 0.5))
    if rng.random() < 0.4:
        # 周辺減光
        r = np.sqrt(((xx - W / 2) / W) ** 2 + ((yy - H / 2) / H) ** 2)
        img = img * (1 - r[..., None] * rng.uniform(0, 0.6))
    if rng.random() < 0.5:
        img = cv2.GaussianBlur(img, (0, 0), rng.uniform(0.3, 1.3))
    return np.clip(img, 0, 1)


def white_balance(rng, img):
    """画面全体の色温度のずれ (紙も机も同じ照明の色を帯びる。float BGR 0..1)。
    紙の絶対的な白さではなく、紙と机の色の違いで見分けるようにするため。"""
    t = rng.uniform(-0.15, 0.15)  # + で暖色 (赤寄り)、- で寒色 (青寄り)
    gains = np.array([1 - t, 1 + rng.uniform(-0.04, 0.04), 1 + t], np.float32)
    return np.clip(img * gains, 0, 1)


def warm_desk(rng, width, height):
    """明るさが紙に近いベージュ・木目の机 (float BGR 0..1)。灰色では紙と区別しにくい。"""
    v = rng.uniform(0.45, 0.88)
    w = rng.uniform(0.03, 0.18)  # 黄み (b* が正) の強さ
    base = np.array([v * (1 - w), v * (1 + w * 0.15), v * (1 + w * 0.6)], np.float32)
    img = np.broadcast_to(base, (height, width, 3)).copy()
    yy, xx = np.mgrid[:height, :width].astype(np.float32)
    if rng.random() < 0.5:
        angle = rng.uniform(0, np.pi)
        u = xx * np.cos(angle) + yy * np.sin(angle)
        grain = np.sin(u / rng.uniform(3, 14) + 0.7 * np.sin(u / 45))
        img *= 1 + grain[..., None] * rng.uniform(0.01, 0.06)
    # 机の上の小物 (キーボード・マウス・ケーブル相当の暗い・白い物体)
    for _ in range(int(rng.integers(0, 4))):
        x0, y0 = rng.uniform(-0.2, 0.9) * width, rng.uniform(-0.2, 0.9) * height
        x1 = x0 + rng.uniform(0.1, 0.6) * width
        y1 = y0 + rng.uniform(0.05, 0.25) * height
        color = (rng.uniform(0.05, 0.3, 3) if rng.random() < 0.6
                 else np.full(3, rng.uniform(0.8, 0.98))).tolist()
        cv2.rectangle(img, (int(x0), int(y0)), (int(x1), int(y1)), color, -1)
    img += rng.normal(0, 0.008, (height, width, 1)).astype(np.float32)
    return np.clip(img, 0, 1).astype(np.float32)


def to_gray(img):
    """アプリ (DocumentDetector.toGray) と同じ輝度 (BGR 入力)。"""
    return img[..., 2] * 0.299 + img[..., 1] * 0.587 + img[..., 0] * 0.114


def squash(rng, gray, mask):
    """アプリの前処理: 縦横比を無視して 256x256 に。縮小法は面積平均/双線形を混ぜる。"""
    interp = cv2.INTER_AREA if rng.random() < 0.5 else cv2.INTER_LINEAR
    g = cv2.resize(gray, (IMG, IMG), interpolation=interp)
    m = cv2.resize(mask, (IMG, IMG), interpolation=cv2.INTER_AREA)
    return g, (m > 0.5).astype(np.float32)


def _pick(rng, papers, p_procedural=0.0):
    if p_procedural > 0 and rng.random() < p_procedural:
        return procedural_paper(rng)
    return papers[int(rng.integers(len(papers)))]


def add_corner_object(rng, canvas, mask, dst):
    """主な紙の角のそばにスマホ・カップ・手を置く。半分は角を覆い、半分は紙の下にあって
    角は見えている。覆う場面だけだと「角のそばの物 = 紙が下に続く」と覚え、実写で紙の
    そばにあるカメラや台まで紙に含めた (v6)。正解はどちらも紙全体の四角形。"""
    covered = corner_object(rng, canvas, dst)
    if rng.random() < 0.5:
        return covered
    return covered * (1 - mask[..., None]) + canvas * mask[..., None]


def paste_scene(rng, canvas, papers, p_multi, p_occluder, p_panel=0.0,
                p_procedural=0.0, synth_profile="legacy", p_clipped=0.0, p_stack=0.0,
                p_fold=0.0, p_corner_object=0.0, p_same=0.0):
    """紙を貼る。正解マスクは「主な 1 枚」の四角形全体だけ。

    - 単独 (既定): 1 枚だけ貼る
    - 複数枚 (p_multi): 奥の紙を 1〜2 枚貼ってから、主な紙を一番手前に貼る。
      奥の紙は主な紙と同程度以下の大きさで、主な紙の近くに重なるように置く
      (実写の「楽譜が何枚も重なった机」。v2 は複数枚を 1 つに塗ってしまう)
    - 束 (p_stack): 主な紙の下に 1〜3 枚をわずかにずらして重ね、手前の 1 枚だけ
      正解にする (実写の「書類の束の上の 1 枚」。下の紙ははみ出して見える)
    - フレームで切れる (p_clipped): 主な紙を大きく貼り、意図的にキャンバス外へ
      出す。正解はキャンバス内の可視部分のみ (Web の野良写真で紙がフレーム端で
      切れているケースへの汎化)
    - 遮蔽物 (p_occluder): 主な紙の上に小さな紙 (付箋・カード相当) を載せる。
      正解は隠れた部分も含めた主な紙の四角形全体 (四隅を求めたいので)
    - 同じ紙 (p_same): 複数枚・束のとき、下の紙を主な紙と同じ素材にする (同じ色紙の重なり)
    - 角の折り返し・めくれ (p_fold) と角を覆う物 (p_corner_object) は、フレームで切れる場合
      以外の主な紙に重ねてかける
    """
    H, W = canvas.shape[:2]
    u = rng.random()
    if u < p_multi + p_stack:
        same = _pick(rng, papers, p_procedural) if p_same > 0 and rng.random() < p_same else None

        def under():
            return same if same is not None else _pick(rng, papers, p_procedural)

        def main():
            return same if same is not None else _pick(rng, papers, p_procedural)

        def finish(out):
            if p_corner_object > 0 and rng.random() < p_corner_object:
                return add_corner_object(rng, *out), out[1], out[2]
            return out
    if u < p_multi:
        main_area = rng.uniform(0.12, 0.55)
        cx, cy = rng.uniform(0.3, 0.7) * W, rng.uniform(0.3, 0.7) * H
        side = math.sqrt(main_area * W * H)
        for _ in range(int(rng.integers(1, 3))):
            ang = rng.uniform(0, 2 * np.pi)
            dist = rng.uniform(0.2, 0.75) * side
            bc = (cx + math.cos(ang) * dist, cy + math.sin(ang) * dist)
            canvas, _, _ = paste_paper(rng, canvas, under(), True,
                                       area=main_area * rng.uniform(0.6, 1.05), center=bc)
        return finish(paste_paper(rng, canvas, main(), False,
                                  area=main_area, center=(cx, cy), p_panel=p_panel, p_fold=p_fold))
    if u < p_multi + p_stack:
        # 下の紙は手前の紙と同サイズ ±15% で、小さな回転・平行移動の差だけつける
        main_area = rng.uniform(0.15, 0.5)
        cx, cy = rng.uniform(0.35, 0.65) * W, rng.uniform(0.35, 0.65) * H
        side = math.sqrt(main_area * W * H)
        for _ in range(int(rng.integers(1, 4))):
            ang = rng.uniform(0, 2 * np.pi)
            dist = rng.uniform(0.05, 0.35) * side
            bc = (cx + math.cos(ang) * dist, cy + math.sin(ang) * dist)
            canvas, _, _ = paste_paper(rng, canvas, under(), True,
                                       area=main_area * rng.uniform(0.85, 1.15), center=bc)
        return finish(paste_paper(rng, canvas, main(), False,
                                  area=main_area, center=(cx, cy), p_panel=p_panel, p_fold=p_fold))
    if u < p_multi + p_stack + p_clipped:
        # 大きめの紙を意図的にキャンバス外へ出す。正解マスクは paste_paper の
        # alpha (= キャンバス内の可視部分)。可視面積が 92% 超 (紙が全面を覆う)
        # や 15% 未満 (見えすぎ/見えなさすぎ) は貼り直す。アプリの推論も
        # マスク面積がほぼ全面 (97%+) は「判定不能」で拒否するため。
        best = None
        for _ in range(4):
            edge = int(rng.integers(4))
            if edge < 2:
                cx = (0.02 if edge == 0 else 0.98) * W
                cy = rng.uniform(0.3, 0.7) * H
            else:
                cx = rng.uniform(0.3, 0.7) * W
                cy = (0.02 if edge == 2 else 0.98) * H
            out = paste_paper(rng, canvas, _pick(rng, papers, p_procedural), True,
                              area=rng.uniform(0.4, 1.2), center=(cx, cy), p_panel=p_panel)
            vis = out[1].sum() / (W * H)
            if 0.15 <= vis <= 0.92:
                return out
            if best is None or abs(vis - 0.5) < abs(best[0] - 0.5):
                best = (vis, out)
        return best[1]
    canvas, mask, dst = paste_paper(rng, canvas, _pick(rng, papers, p_procedural), rng.random() < 0.15,
                                    p_panel=p_panel, p_fold=p_fold)
    if p_corner_object > 0 and rng.random() < p_corner_object:
        canvas = add_corner_object(rng, canvas, mask, dst)
    if u < p_multi + p_stack + p_clipped + p_occluder:
        if synth_profile == "diverse" and rng.random() < 0.5:
            return object_occluder(rng, canvas, dst), mask, dst
        main_area = float(mask.sum()) / (W * H)
        # 主な紙の内側 (辺寄り) を中心に小さな紙を載せる
        t = rng.uniform(0.1, 0.9, 2)
        a = dst[0] + (dst[1] - dst[0]) * t[0]
        b = dst[3] + (dst[2] - dst[3]) * t[0]
        oc = a + (b - a) * (t[1] if rng.random() < 0.5 else rng.choice([0.05, 0.95]))
        canvas, _, _ = paste_paper(rng, canvas, _pick(rng, papers, p_procedural), True,
                                   area=max(0.01, main_area * rng.uniform(0.05, 0.3)),
                                   center=(float(oc[0]), float(oc[1])))
    return canvas, mask, dst


def synthesis_options(synth_profile="legacy", **overrides):
    """学習・プレビュー・保存で同じ確率設定を使用する。"""
    options = dict(PROFILE_DEFAULTS[synth_profile])
    options.update({k: v for k, v in overrides.items() if v is not None})
    for name, value in options.items():
        if not 0 <= value <= 1:
            raise ValueError(f"{name} must be between 0 and 1")
    if options["p_multi"] + options["p_stack"] + options["p_clipped"] + options["p_occluder"] > 1:
        raise ValueError("p_multi + p_stack + p_clipped + p_occluder must be <= 1")
    if options["p_negative"] > 0.85:
        raise ValueError("p_negative must be <= 0.85 (15% original scenes)")
    return dict(synth_profile=synth_profile, **options)


def make_composite(rng, papers, bgs, want_canvas=False, p_multi=None, p_occluder=None,
                   p_panel=None, p_procedural=None, p_negative=None, synth_profile="legacy",
                   p_clipped=None, p_stack=None, p_fold=None, p_corner_object=None, p_same=None,
                   color=False):
    """1 サンプル。want_canvas=True なら評価書き出し用に canvas と四隅も返す。

    color=False は灰色 [H,W]、color=True は RGB [H,W,3] (どちらも 0..1) を返す。"""
    opts = synthesis_options(synth_profile, p_multi=p_multi, p_occluder=p_occluder,
                             p_panel=p_panel, p_procedural=p_procedural,
                             p_negative=p_negative, p_clipped=p_clipped, p_stack=p_stack,
                             p_fold=p_fold, p_corner_object=p_corner_object, p_same=p_same)
    W, H = rand_canvas(rng)
    r = rng.random()
    dst = None
    if r < 0.15:
        # 生成写真そのもの (紙 + その写真の背景) を少しだけ切り抜き直す
        _, im, q = papers[int(rng.integers(len(papers)))]
        h, w = im.shape[:2]
        s = rng.uniform(0.8, 1.0)
        cw, ch = w * s, h * s
        x0, y0 = rng.uniform(0, w - cw), rng.uniform(0, h - ch)
        crop = im[int(y0):int(y0 + ch), int(x0):int(x0 + cw)]
        sx, sy = W / crop.shape[1], H / crop.shape[0]
        canvas = cv2.resize(crop, (W, H), interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0
        dst = (q - [int(x0), int(y0)]) * [sx, sy]
        mask = np.zeros((H, W), np.float32)
        cv2.fillPoly(mask, [dst.round().astype(np.int32)], 1.0)
    else:
        canvas = None
        if color and rng.random() < 0.25:
            canvas = warm_desk(rng, W, H)
        elif rng.random() < (0.60 if synth_profile == "diverse" else 0.75):
            canvas = crop_bg(rng, bgs, W, H)
        if canvas is None:
            canvas = (procedural_background(rng, W, H) if synth_profile == "diverse"
                      else procedural_bg(rng, W, H))
        if r < 0.15 + opts["p_negative"]:
            mask = np.zeros((H, W), np.float32)  # 紙なし (ネガティブ)
        else:
            canvas, mask, dst = paste_scene(rng, canvas, papers, opts["p_multi"],
                                            opts["p_occluder"], opts["p_panel"],
                                            opts["p_procedural"], synth_profile,
                                            p_clipped=opts["p_clipped"],
                                            p_stack=opts["p_stack"], p_fold=opts["p_fold"],
                                            p_corner_object=opts["p_corner_object"],
                                            p_same=opts["p_same"])
    canvas = photometric(rng, canvas)
    if color:
        canvas = white_balance(rng, canvas)
    if synth_profile == "diverse":
        canvas = camera_effects(rng, canvas)
    k = int(rng.integers(4))  # センサー向き (縦持ち/横持ち) の 90 度回転
    if k:
        canvas = np.rot90(canvas, k).copy()
        mask = np.rot90(mask, k).copy()
        if dst is not None:
            # 反時計回り 90 度 x k: (x, y) -> (y, W-1-x) を k 回
            for _ in range(k):
                w_now = W
                dst = np.stack([dst[:, 1], w_now - 1 - dst[:, 0]], 1)
                W, H = H, W
    if color:
        return _finish_color(rng, canvas, mask, dst, want_canvas)
    gray = to_gray(canvas)
    g, m = squash(rng, gray, mask)
    g = g + rng.normal(0, rng.uniform(0, 0.03), g.shape)
    g = np.clip(g, 0, 1).astype(np.float32)
    if rng.random() < 0.3:
        ok, enc = cv2.imencode(".jpg", (g * 255).astype(np.uint8),
                               [cv2.IMWRITE_JPEG_QUALITY, int(rng.integers(40, 90))])
        g = cv2.imdecode(enc, cv2.IMREAD_GRAYSCALE).astype(np.float32) / 255.0
    if want_canvas:
        return g, m, canvas, dst
    return g, m


def _finish_color(rng, canvas, mask, dst, want_canvas):
    """色モードの仕上げ: RGB にして縮小・ノイズ・JPEG 劣化。"""
    rgb = np.ascontiguousarray(canvas[..., ::-1])
    x, m = squash(rng, rgb, mask)
    s = rng.uniform(0, 0.03)
    x = x + rng.normal(0, s, (IMG, IMG, 1)) + rng.normal(0, s * 0.3, x.shape)
    x = np.clip(x, 0, 1).astype(np.float32)
    if rng.random() < 0.3:
        ok, enc = cv2.imencode(".jpg", (x[..., ::-1] * 255).astype(np.uint8),
                               [cv2.IMWRITE_JPEG_QUALITY, int(rng.integers(40, 90))])
        x = cv2.imdecode(enc, cv2.IMREAD_COLOR)[..., ::-1].astype(np.float32) / 255.0
    if rng.random() < 0.08:
        # 色が当てにならない場面 (色の抜けた照明など) でも明るさだけで見つけられるように
        x = np.repeat(to_gray(x[..., ::-1])[..., None], 3, axis=2)
    x = np.ascontiguousarray(x, dtype=np.float32)
    if want_canvas:
        return x, m, canvas, dst
    return x, m


def to_chw(x):
    """灰色 [H,W] / RGB [H,W,3] を [C,H,W] にする。"""
    return x[None] if x.ndim == 2 else np.ascontiguousarray(x.transpose(2, 0, 1))


class CompositeStream(IterableDataset):
    def __init__(self, seed, split="train", color=False, **options):
        self.seed = seed
        self.split = split
        self.color = color
        self.options = synthesis_options(**options)

    def __iter__(self):
        info = get_worker_info()
        wid = info.id if info else 0
        rng = np.random.default_rng(self.seed + 1000 * wid)
        cv2.setNumThreads(1)
        papers, bgs = load_assets()
        pool = papers[self.split]
        while True:
            g, m = make_composite(rng, pool, bgs, color=self.color, **self.options)
            yield torch.from_numpy(to_chw(g)), torch.from_numpy(m[None])


# ---------------------------------------------------------------- モデル

class PaperSegV2(nn.Module):
    """MobileNetV3-Small エンコーダ + 軽量 U-Net デコーダ。入出力は v1 と同じ。"""

    def __init__(self, pretrained=True):
        super().__init__()
        import torchvision

        weights = torchvision.models.MobileNet_V3_Small_Weights.IMAGENET1K_V1 if pretrained else None
        feats = torchvision.models.mobilenet_v3_small(weights=weights).features
        # stride: f0=2(16ch) f1=4(16) f2-3=8(24) f4-8=16(48) f9-11=32(96)
        self.s2 = feats[0]
        self.s4 = feats[1]
        self.s8 = feats[2:4]
        self.s16 = feats[4:9]
        self.s32 = feats[9:12]
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

        def up(cin, cskip, cout):
            return nn.Sequential(
                nn.Conv2d(cin + cskip, cout, 3, padding=1, bias=False),
                nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
                nn.Conv2d(cout, cout, 3, padding=1, bias=False),
                nn.BatchNorm2d(cout), nn.ReLU(inplace=True),
            )

        self.d16 = up(96, 48, 64)
        self.d8 = up(64, 24, 48)
        self.d4 = up(48, 16, 32)
        self.d2 = up(32, 16, 16)
        # 1/2 解像度でロジットを出し、最後に双線形で 256 へ (全解像度の畳み込みは重いため)
        self.head = nn.Conv2d(16, 1, 1)

    def forward(self, x):
        g = x
        if x.shape[1] == 1:
            x = x.repeat(1, 3, 1, 1)
        x = (x - self.mean) / self.std
        f2 = self.s2(x)
        f4 = self.s4(f2)
        f8 = self.s8(f4)
        f16 = self.s16(f8)
        f32 = self.s32(f16)

        def cat_up(a, skip):
            return torch.cat([F.interpolate(a, size=skip.shape[-2:], mode="bilinear",
                                            align_corners=False), skip], 1)

        y = self.d16(cat_up(f32, f16))
        y = self.d8(cat_up(y, f8))
        y = self.d4(cat_up(y, f4))
        y = self.d2(cat_up(y, f2))
        return F.interpolate(self.head(y), size=g.shape[-2:], mode="bilinear",
                             align_corners=False)


def dice_loss(logits, y):
    p = torch.sigmoid(logits)
    inter = (p * y).sum((1, 2, 3))
    den = p.sum((1, 2, 3)) + y.sum((1, 2, 3))
    # 紙なしサンプル (y=0) は dice が不安定なので BCE に任せる
    has = (y.sum((1, 2, 3)) > 0).float()
    d = 1 - (2 * inter + 1) / (den + 1)
    return (d * has).sum() / has.sum().clamp(min=1)


def iou_score(logits, y):
    p = (logits > 0).float()
    inter = (p * y).sum()
    union = ((p + y) > 0).float().sum()
    return (inter / union).item() if union > 0 else 1.0


def load_real_pairs(pair_dir=REAL_PAIRS_DIR, size=IMG, color=False):
    """training_data/train_real (images/ + masks/) の実写ペア。

    promote_captures.py がアプリの補正済み四隅から作ったもの。ネガティブ
    (空マスク) も含む。フォルダが無い/空なら (None, None, None)。
    manifest.json の source に応じたサンプリング重みも返す (難例を厚く)。
    color=True なら RGB [N,H,W,3] で読む (train_hard_gen)。
    """
    img_dir = os.path.join(pair_dir, "images")
    mask_dir = os.path.join(pair_dir, "masks")
    if not os.path.isdir(mask_dir):
        return None, None, None, None
    manifest = {}
    mp = os.path.join(pair_dir, "manifest.json")
    if os.path.exists(mp):
        with open(mp, encoding="utf-8") as fp:
            manifest = json.load(fp)
    weight_by_source = {
        "hard_negative_mined": 8.0,       # モデルが実際にミスした難例
        "stripe_negative_synthesis": 4.0,  # ストライプ系の既知の失敗モード
    }
    xs, ys, ids, ws = [], [], [], []
    for f in sorted(os.listdir(mask_dir)):
        if not f.endswith("_mask.png"):
            continue
        stem = f[: -len("_mask.png")]
        jpg = os.path.join(img_dir, stem + ".jpg")
        if not os.path.exists(jpg):
            continue
        im = cv2.imread(jpg, cv2.IMREAD_COLOR if color else cv2.IMREAD_GRAYSCALE)
        mk = cv2.imread(os.path.join(mask_dir, f), cv2.IMREAD_GRAYSCALE)
        if im is None or mk is None or im.shape[:2] != mk.shape[:2]:
            print(f"warn: real pair {stem} を読み飛ばし (画像/マスク不正)")
            continue
        im = cv2.resize(im, (size, size), interpolation=cv2.INTER_AREA)
        mk = cv2.resize(mk, (size, size), interpolation=cv2.INTER_NEAREST)
        if color:
            im = im[..., ::-1]
        xs.append(im.astype(np.float32) / 255.0)
        ys.append((mk > 127).astype(np.float32))
        ids.append(stem)
        ws.append(weight_by_source.get(manifest.get(stem, {}).get("source", ""), 1.0))
    if not xs:
        return None, None, None, None
    w = np.asarray(ws, dtype=np.float64)
    x = np.stack(xs)
    return (x if color else x[..., None]), np.stack(ys)[..., None], ids, w / w.sum()


def augment_real_pair(x, y, rng):
    """実写ペアへの軽いオーギュメンテーション (反転・90 度回転・輝度)。"""
    if rng.random() < 0.5:
        x, y = x[:, ::-1], y[:, ::-1]
    if rng.random() < 0.5:
        x, y = x[::-1, :], y[::-1, :]
    k = int(rng.integers(0, 4))
    if k:
        x, y = np.rot90(x, k), np.rot90(y, k)
    b = rng.uniform(0.85, 1.15)
    c = rng.uniform(0.9, 1.1)
    x = np.clip((x - 0.5) * c + 0.5 + (b - 1.0) * 0.3, 0.0, 1.0)
    return np.ascontiguousarray(x), np.ascontiguousarray(y)


def load_saved_synthetic(dirs, size=IMG):
    """保存済み合成セットの奇数 id (学習側) を読み込む。偶数 id (holdout) は読まない。

    戻り値: (x [N,H,W,1] float32, y [N,H,W,1] float32, 内訳 dict)。
    """
    xs, ys, summary = [], [], {}
    for d in dirs:
        with open(os.path.join(d, "manifest.jsonl"), encoding="utf-8") as fp:
            records = [json.loads(line) for line in fp]
        used = [r for r in records if int(r["id"]) % 2 == 1]
        pos = 0
        for r in used:
            im = cv2.imread(os.path.join(d, r["image"]), cv2.IMREAD_GRAYSCALE)
            mk = cv2.imread(os.path.join(d, r["mask"]), cv2.IMREAD_GRAYSCALE)
            if im is None or mk is None or im.shape != (size, size) or mk.shape != im.shape:
                raise ValueError(f"invalid saved pair: {d} {r['id']}")
            if bool(mk.any()) != r["paper_present"]:
                raise ValueError(f"label mismatch: {d} {r['id']}")
            xs.append(im.astype(np.float32) / 255.0)
            ys.append((mk > 127).astype(np.float32))
            pos += int(r["paper_present"])
        name = os.path.relpath(d, os.path.join(ROOT, "training_data")).replace(os.sep, "/")
        summary[name] = dict(used=len(used), positive=pos, negative=len(used) - pos,
                             holdout_excluded=len(records) - len(used))
    if not xs:
        return None, None, summary
    return np.stack(xs)[..., None], np.stack(ys)[..., None], summary


def mix_real_pairs(x, y, rx, ry, rng, ratio, p=None, slots=None):
    """バッチの一部を実写ペアで置き換える。p があれば重み付きサンプリング。

    slots を渡すとその位置だけを置き換える (保存合成との重複を避けるため)。
    """
    if slots is None:
        n = min(len(rx), int(round(x.shape[0] * ratio)))
        if n <= 0:
            return x, y
        slots = rng.choice(x.shape[0], n, replace=False)
    n = len(slots)
    if n <= 0:
        return x, y
    picks = rng.choice(len(rx), n, replace=True, p=p)
    for j, i in zip(slots, picks):
        ax, ay = augment_real_pair(rx[i], ry[i], rng)
        # 灰色のペアを色モードのバッチに入れるときは R=G=B にする
        x[j] = torch.from_numpy(ax.transpose(2, 0, 1).copy()).expand(x.shape[1], -1, -1)
        y[j] = torch.from_numpy(ay.transpose(2, 0, 1).copy())
    return x, y


def fixed_val_set(n, seed=123, color=False):
    rng = np.random.default_rng(seed)
    papers, bgs = load_assets()
    xs, ys = [], []
    for _ in range(n):
        g, m = make_composite(rng, papers["val"], bgs, color=color)
        xs.append(to_chw(g))
        ys.append(m[None])
    return torch.from_numpy(np.stack(xs)), torch.from_numpy(np.stack(ys))


def onnx_iou(path, vx, vy):
    import onnxruntime as ort

    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    channels = sess.get_inputs()[0].shape[1]
    ious = []
    for i in range(len(vx)):
        x = vx[i:i + 1].numpy()
        if channels == 1 and x.shape[1] == 3:
            # 灰色のモデル (現行) と比べるときはアプリと同じ輝度にして渡す
            x = (x[:, 0:1] * 0.299 + x[:, 1:2] * 0.587 + x[:, 2:3] * 0.114).astype(np.float32)
        out = sess.run(None, {sess.get_inputs()[0].name: x})[0]
        ious.append(iou_score(torch.from_numpy(out), vy[i:i + 1]))
    return float(np.mean(ious))


def preview(n, out_path, seed=1, color=False, **options):
    rng = np.random.default_rng(seed)
    papers, bgs = load_assets()
    tiles = []
    for _ in range(n):
        g, m = make_composite(rng, papers["train"], bgs, color=color, **options)
        if color:
            t = np.ascontiguousarray((g[..., ::-1] * 255).astype(np.uint8))
        else:
            t = cv2.cvtColor((g * 255).astype(np.uint8), cv2.COLOR_GRAY2BGR)
        cnts, _ = cv2.findContours((m > 0.5).astype(np.uint8), cv2.RETR_EXTERNAL,
                                   cv2.CHAIN_APPROX_SIMPLE)
        cv2.drawContours(t, cnts, -1, (40, 40, 240), 2)
        tiles.append(t)
    cols = 8
    rows = (n + cols - 1) // cols
    sheet = np.zeros((rows * IMG, cols * IMG, 3), np.uint8)
    for i, t in enumerate(tiles):
        r, c = divmod(i, cols)
        sheet[r * IMG:(r + 1) * IMG, c * IMG:(c + 1) * IMG] = t
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    if not cv2.imwrite(out_path, sheet):
        raise OSError(f"cannot write preview: {out_path}")
    print("preview:", out_path)


def export_synthetic(n, out_dir, seed=1, **options):
    """アプリ入力と同じ 256x256 画像・正解マスクを保存。既存の保存先は上書きしない。"""
    options = synthesis_options(**options)
    papers, bgs = load_assets()
    os.makedirs(out_dir, exist_ok=False)
    os.makedirs(os.path.join(out_dir, "images"))
    os.makedirs(os.path.join(out_dir, "masks"))
    rng = np.random.default_rng(seed)
    positives = 0
    with open(os.path.join(out_dir, "manifest.jsonl"), "w", encoding="utf-8") as fp:
        for i in range(n):
            g, m, canvas, quad = make_composite(rng, papers["train"], bgs,
                                               want_canvas=True, **options)
            stem = f"{i + 1:06d}"
            image_path = f"images/{stem}.png"
            mask_path = f"masks/{stem}_mask.png"
            for path, img in ((image_path, (g * 255).round().astype(np.uint8)),
                              (mask_path, (m * 255).astype(np.uint8))):
                if not cv2.imwrite(os.path.join(out_dir, path), img):
                    raise OSError(f"cannot write: {path}")
            positives += int(m.any())
            height, width = canvas.shape[:2]
            record = dict(id=stem, image=image_path, mask=mask_path, width=IMG, height=IMG,
                          paper_present=bool(m.any()), split="train",
                          corners=(quad / [width, height]).tolist() if quad is not None else None)
            fp.write(json.dumps(record, ensure_ascii=False) + "\n")
    with open(os.path.join(out_dir, "config.json"), "w", encoding="utf-8") as fp:
        json.dump(dict(seed=seed, count=n, positive=positives, negative=n - positives,
                       options=options, label_policy="full_main_page_including_occlusion",
                       source_papers=[p[0] for p in papers["train"]],
                       source_backgrounds=sorted({b[0] for b in bgs})),
                  fp, ensure_ascii=False, indent=2)
    print(f"synthetic: {out_dir} ({n} pairs; paper {positives}, negative {n - positives})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", type=int, default=4000)
    ap.add_argument("--batch", type=int, default=24)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--threads", type=int, default=6)
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "paper_seg_v2.onnx"))
    ap.add_argument("--baseline", default=os.path.join(ROOT, "assets", "models", "paper_seg.onnx"))
    ap.add_argument("--preview", type=int, default=0)
    ap.add_argument("--seed", type=int, default=1, help="プレビュー・保存用の生成シード")
    ap.add_argument("--preview-out", default=os.path.join(ROOT, "build", "v2_preview.jpg"))
    ap.add_argument("--export-synth", type=int, default=0, help="合成画像とマスクを指定枚数保存 (学習はしない)")
    ap.add_argument("--synth-out", default=os.path.join(ROOT, "training_data", "synthetic_diverse"))
    ap.add_argument("--synth-profile", choices=tuple(PROFILE_DEFAULTS), default="diverse",
                    help="diverse: 多様な素材・撮影条件 (既定), legacy: 従来条件")
    ap.add_argument("--p-procedural", type=float, default=None,
                    help="貼り付ける紙を手続き生成素材に置換する確率 (diverse: 0.30)")
    ap.add_argument("--p-negative", type=float, default=None,
                    help="紙なし画像の割合 (diverse: 0.12, legacy: 0.05)")
    ap.add_argument("--p-multi", type=float, default=None,
                    help="複数枚の紙 (主な 1 枚だけが正解) の割合")
    ap.add_argument("--p-occluder", type=float, default=None,
                    help="主な紙に小さな紙や小物を載せる割合 (正解は主な紙の四角形全体)")
    ap.add_argument("--p-panel", type=float, default=None,
                    help="紙の内側に色ブロックを描く割合 (正解は紙全体)")
    ap.add_argument("--p-clipped", type=float, default=None,
                    help="主な紙をフレーム外へ出す割合 (正解はキャンバス内の可視部分)")
    ap.add_argument("--p-stack", type=float, default=None,
                    help="主な紙の下にずらした紙を重ねる割合 (正解は手前の 1 枚)")
    ap.add_argument("--p-fold", type=float, default=None,
                    help="主な紙の角を折り返す/めくる確率")
    ap.add_argument("--p-corner-object", type=float, default=None,
                    help="主な紙の角をスマホ・カップ・手で覆う確率")
    ap.add_argument("--p-same", type=float, default=None,
                    help="複数枚・束で下の紙を主な紙と同じ素材にする確率")
    ap.add_argument("--init-pth", default="", help="この重みから学習を始める (例: build/paper_seg_v2.pth)")
    ap.add_argument("--color", action="store_true",
                    help="入力を RGB 3ch にする (1x3x256x256)。灰色のモデルの重みから始めてもよい")
    ap.add_argument("--real-pairs-dir", default=REAL_PAIRS_DIR,
                    help="promote_captures.py が作った実写ペア (images/ + masks/)。あれば混合する")
    ap.add_argument("--real-ratio", type=float, default=0.2,
                    help="バッチ中の実写ペアの割合 (0 で無効)")
    ap.add_argument("--synth-sets", nargs="*", default=SAVED_SYNTH_DIRS,
                    help="バッチに混ぜる保存済み合成セット (奇数 id のみ使用)")
    ap.add_argument("--synth-ratio", type=float, default=0.4,
                    help="バッチ中の保存済み合成セットの割合 (0 で無効、残りはその場生成)")
    ap.add_argument("--color-pairs", nargs="*", default=COLOR_PAIRS_DIRS,
                    help="RGB のまま混ぜる学習ペア (images/ + masks/)。--color のときだけ使う")
    ap.add_argument("--color-pair-ratio", type=float, default=0.0,
                    help="バッチ中の色付き学習ペアの割合 (0 で無効)")
    args = ap.parse_args()
    try:
        options = synthesis_options(args.synth_profile, p_multi=args.p_multi,
                                    p_occluder=args.p_occluder, p_panel=args.p_panel,
                                    p_procedural=args.p_procedural, p_negative=args.p_negative,
                                    p_clipped=args.p_clipped, p_stack=args.p_stack,
                                    p_fold=args.p_fold, p_corner_object=args.p_corner_object,
                                    p_same=args.p_same)
    except ValueError as exc:
        ap.error(str(exc))
    if args.preview < 0 or args.export_synth < 0:
        ap.error("--preview and --export-synth must be >= 0")
    if args.preview and args.export_synth:
        ap.error("choose either --preview or --export-synth")
    cv2.setNumThreads(1)
    print("synthesis:", json.dumps(options, ensure_ascii=False))

    if args.preview:
        preview(args.preview, args.preview_out, seed=args.seed, color=args.color, **options)
        return
    if args.export_synth and args.color:
        ap.error("--export-synth は灰色のみ対応")
    if args.export_synth:
        export_synthetic(args.export_synth, args.synth_out, seed=args.seed, **options)
        return

    torch.manual_seed(0)
    torch.set_num_threads(args.threads)
    model = PaperSegV2(pretrained=not args.init_pth)
    if args.init_pth:
        model.load_state_dict(torch.load(args.init_pth, map_location="cpu"))
        print("init from", args.init_pth)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"params: {n_params:,} ({n_params * 4 / 1e6:.2f} MB fp32)")

    vx, vy = fixed_val_set(256, color=args.color)
    if os.path.exists(args.baseline):
        print(f"baseline {os.path.basename(args.baseline)} val IoU: {onnx_iou(args.baseline, vx, vy):.4f}")

    loader = DataLoader(CompositeStream(seed=42, color=args.color, **options),
                        batch_size=args.batch,
                        num_workers=args.workers, persistent_workers=args.workers > 0)
    rx, ry, real_ids, real_p = load_real_pairs(args.real_pairs_dir)
    real_rng = np.random.default_rng(7)
    use_real = rx is not None and args.real_ratio > 0
    if use_real:
        n_neg = int(sum(ry[i].sum() == 0 for i in range(len(ry))))
        print(f"real pairs: {len(rx)} (紙なし {n_neg}) をバッチの {args.real_ratio:.0%} に混合"
              f" (難例重み付き)")
    else:
        print("real pairs: なし (合成のみで学習)")
    sx = sy = None
    saved_summary = {}
    if args.synth_ratio > 0:
        sx, sy, saved_summary = load_saved_synthetic(args.synth_sets)
        if sx is None:
            ap.error("--synth-ratio > 0 ですが保存済み合成セットが空です")
        for name, c in saved_summary.items():
            print(f"saved synth: {name}: {c['used']} 組 (紙あり {c['positive']} / 紙なし "
                  f"{c['negative']}, holdout {c['holdout_excluded']} は除外)")
        print(f"saved synth: 計 {len(sx)} 組をバッチの {args.synth_ratio:.0%} に混合")
    cx_pairs = cy_pairs = None
    color_summary = {}
    if args.color_pair_ratio > 0:
        if not args.color:
            ap.error("--color-pair-ratio は --color と一緒に使う")
        parts = []
        for d in args.color_pairs:
            px, py, pids, _ = load_real_pairs(d, color=True)
            if px is None:
                ap.error(f"色付きの学習ペアがありません: {d}")
            parts.append((px, py))
            color_summary[os.path.relpath(d, os.path.join(ROOT, "training_data")).replace(os.sep, "/")] = len(px)
        cx_pairs = np.concatenate([p[0] for p in parts])
        cy_pairs = np.concatenate([p[1] for p in parts])
        print(f"color pairs: {color_summary} をバッチの {args.color_pair_ratio:.0%} に混合")
    n_real = int(round(args.batch * args.real_ratio)) if use_real else 0
    n_saved = int(round(args.batch * args.synth_ratio)) if sx is not None else 0
    n_color = int(round(args.batch * args.color_pair_ratio)) if cx_pairs is not None else 0
    if n_real + n_saved + n_color > args.batch:
        ap.error("--real-ratio・--synth-ratio・--color-pair-ratio の合計が 1 を超えています")
    print(f"batch {args.batch}: その場生成 {args.batch - n_real - n_saved - n_color} / 保存合成 {n_saved}"
          f" / train_real {n_real} / 色付きペア {n_color}")
    saved_seen = np.zeros(len(sx), dtype=np.int64) if sx is not None else None
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    warm = 200
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: min(1.0, (s + 1) / warm) * 0.5 * (1 + math.cos(math.pi * min(s, args.steps) / args.steps)))
    bce = nn.BCEWithLogitsLoss()

    t0 = time.time()
    running = 0.0
    best = -1.0
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    pth = args.out[:-5] + ".pth"
    it = iter(loader)
    for step in range(1, args.steps + 1):
        model.train()
        x, y = next(it)
        slots = real_rng.permutation(x.shape[0])
        if n_real:
            x, y = mix_real_pairs(x, y, rx, ry, real_rng, args.real_ratio, p=real_p,
                                  slots=slots[:n_real])
        if n_saved:
            picks = real_rng.choice(len(sx), n_saved, replace=False)
            saved_seen[picks] += 1
            x, y = mix_real_pairs(x, y, sx[picks], sy[picks], real_rng, 1.0,
                                  slots=slots[n_real:n_real + n_saved])
        if n_color:
            x, y = mix_real_pairs(x, y, cx_pairs, cy_pairs, real_rng, 1.0,
                                  slots=slots[n_real + n_saved:n_real + n_saved + n_color])
        logits = model(x)
        loss = bce(logits, y) + dice_loss(logits, y)
        opt.zero_grad()
        loss.backward()
        opt.step()
        sched.step()
        running += loss.item()
        if step % 250 == 0 or step == args.steps:
            model.eval()
            with torch.no_grad():
                ious = [iou_score(model(vx[i:i + 32]), vy[i:i + 32]) for i in range(0, len(vx), 32)]
            v = float(np.mean(ious))
            if v > best:
                best = v
                torch.save(model.state_dict(), pth)
            print(f"step {step:5d}/{args.steps} loss {running / 250:.4f} val_iou {v:.4f} "
                  f"best {best:.4f} ({time.time() - t0:.0f}s)", flush=True)
            running = 0.0

    model.load_state_dict(torch.load(pth, map_location="cpu"))
    model.eval()
    channels = 3 if args.color else 1
    torch.onnx.export(model, torch.zeros(1, channels, IMG, IMG), args.out,
                      input_names=["input"], output_names=["output"],
                      opset_version=17, do_constant_folding=True, dynamo=False)
    print(f"exported: {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"exported val IoU: {onnx_iou(args.out, vx, vy):.4f} (チェックポイント選択に使用)")
    # 選択に使っていない別シードのテストセット。背景素材は学習と共通なので
    # 実写での性能は ./dev.ps1 eval -Data training_data/eval_heldout で測ること。
    tx, ty = fixed_val_set(256, seed=999, color=args.color)
    print(f"exported test IoU: {onnx_iou(args.out, tx, ty):.4f} (未使用シード)")
    # 学習データの記録 (保存合成が実際に何回使われたかを残す)
    record = dict(out=os.path.basename(args.out), init=args.init_pth or "imagenet",
                  color=args.color,
                  steps=args.steps, batch=args.batch, lr=args.lr, synthesis=options,
                  batch_split=dict(onthefly=args.batch - n_real - n_saved - n_color, saved=n_saved,
                                   train_real=n_real, color_pairs=n_color),
                  train_real=len(rx) if use_real else 0, saved_synth=saved_summary,
                  color_pairs=color_summary)
    if saved_seen is not None:
        record["saved_synth_coverage"] = dict(
            seen_at_least_once=int((saved_seen > 0).sum()), total=len(saved_seen),
            mean_views=round(float(saved_seen.mean()), 2))
        print(f"saved synth coverage: {record['saved_synth_coverage']}")
    with open(args.out[:-5] + ".data.json", "w", encoding="utf-8") as fp:
        json.dump(record, fp, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
