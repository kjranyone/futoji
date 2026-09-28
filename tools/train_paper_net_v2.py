# -*- coding: utf-8 -*-
"""紙面セグメンテーション v2: 貼り付け合成 + 事前学習済み MobileNetV3 エンコーダ。

v1 (train_paper_net.py) からの変更点:
- 教師マスクは BiRefNet の生マスクではなく、四角形を当てはめた「四隅ラベル」
  (tools/prepare_quad_labels.py の quads.json, ok=true のみ) から作る
- 紙 (生成写真から四隅で切り出し) を、実写の散らかった机など別の背景へ
  ランダムな大きさ・位置・回転・射影で貼り付けて学習データを作る
- アプリの前処理 (4:3 / 16:9 のフレームを 256x256 へ縦横比無視で縮小、
  センサー向きのままの 90 度回転) を再現する
- エンコーダは ImageNet 事前学習済み MobileNetV3-Small (BSD-3)。
  入出力はアプリと同じ 1x1x256x256 (グレー 0..1 → ロジット) のまま

使い方:
  tools/.venv/Scripts/python tools/train_paper_net_v2.py --steps 4000
  tools/.venv/Scripts/python tools/train_paper_net_v2.py --preview 24   # 合成サンプルの確認だけ
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

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
PAPER_DIR = os.path.join(ROOT, "training_data", "paper_photos")
REAL_DIR = os.path.join(ROOT, "training_data", "real_captures")
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


def paste_paper(rng, canvas, paper, allow_out, area=None, center=None):
    """紙を canvas に貼り、(canvas, mask(0/1 float), dst_quad) を返す。"""
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
    # 紙自体の明るさ・色味 (照明の違い)
    warped = warped * rng.uniform(0.75, 1.15) * rng.uniform(0.93, 1.07, 3)
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


def to_gray(img):
    """アプリ (DocumentDetector.toGray) と同じ輝度 (BGR 入力)。"""
    return img[..., 2] * 0.299 + img[..., 1] * 0.587 + img[..., 0] * 0.114


def squash(rng, gray, mask):
    """アプリの前処理: 縦横比を無視して 256x256 に。縮小法は面積平均/双線形を混ぜる。"""
    interp = cv2.INTER_AREA if rng.random() < 0.5 else cv2.INTER_LINEAR
    g = cv2.resize(gray, (IMG, IMG), interpolation=interp)
    m = cv2.resize(mask, (IMG, IMG), interpolation=cv2.INTER_AREA)
    return g, (m > 0.5).astype(np.float32)


def _pick(rng, papers):
    return papers[int(rng.integers(len(papers)))]


def paste_scene(rng, canvas, papers, p_multi, p_occluder):
    """紙を貼る。正解マスクは「主な 1 枚」の四角形全体だけ。

    - 単独 (既定): 1 枚だけ貼る
    - 複数枚 (p_multi): 奥の紙を 1〜2 枚貼ってから、主な紙を一番手前に貼る。
      奥の紙は主な紙と同程度以下の大きさで、主な紙の近くに重なるように置く
      (実写の「楽譜が何枚も重なった机」。v2 は複数枚を 1 つに塗ってしまう)
    - 遮蔽物 (p_occluder): 主な紙の上に小さな紙 (付箋・カード相当) を載せる。
      正解は隠れた部分も含めた主な紙の四角形全体 (四隅を求めたいので)
    """
    H, W = canvas.shape[:2]
    u = rng.random()
    if u < p_multi:
        main_area = rng.uniform(0.12, 0.55)
        cx, cy = rng.uniform(0.3, 0.7) * W, rng.uniform(0.3, 0.7) * H
        side = math.sqrt(main_area * W * H)
        for _ in range(int(rng.integers(1, 3))):
            ang = rng.uniform(0, 2 * np.pi)
            dist = rng.uniform(0.2, 0.75) * side
            bc = (cx + math.cos(ang) * dist, cy + math.sin(ang) * dist)
            canvas, _, _ = paste_paper(rng, canvas, _pick(rng, papers), True,
                                       area=main_area * rng.uniform(0.6, 1.05), center=bc)
        return paste_paper(rng, canvas, _pick(rng, papers), False,
                           area=main_area, center=(cx, cy))
    canvas, mask, dst = paste_paper(rng, canvas, _pick(rng, papers), rng.random() < 0.15)
    if u < p_multi + p_occluder:
        main_area = float(mask.sum()) / (W * H)
        # 主な紙の内側 (辺寄り) を中心に小さな紙を載せる
        t = rng.uniform(0.1, 0.9, 2)
        a = dst[0] + (dst[1] - dst[0]) * t[0]
        b = dst[3] + (dst[2] - dst[3]) * t[0]
        oc = a + (b - a) * (t[1] if rng.random() < 0.5 else rng.choice([0.05, 0.95]))
        canvas, _, _ = paste_paper(rng, canvas, _pick(rng, papers), True,
                                   area=max(0.01, main_area * rng.uniform(0.05, 0.3)),
                                   center=(float(oc[0]), float(oc[1])))
    return canvas, mask, dst


def make_composite(rng, papers, bgs, want_canvas=False, p_multi=0.0, p_occluder=0.0):
    """1 サンプル。want_canvas=True なら評価書き出し用に canvas と四隅も返す。"""
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
        if rng.random() < 0.75:
            canvas = crop_bg(rng, bgs, W, H)
        if canvas is None:
            canvas = procedural_bg(rng, W, H)
        if r < 0.20:
            mask = np.zeros((H, W), np.float32)  # 紙なし (ネガティブ)
        else:
            canvas, mask, dst = paste_scene(rng, canvas, papers, p_multi, p_occluder)
    canvas = photometric(rng, canvas)
    k = int(rng.integers(4))  # センサー向き (縦持ち/横持ち) の 90 度回転
    if k:
        canvas = np.rot90(canvas, k).copy()
        mask = np.rot90(mask, k).copy()
        if dst is not None:
            # 反時計回り 90 度 x k: (x, y) -> (y, W-1-x) を k 回
            for _ in range(k):
                w_now = W
                dst = np.stack([dst[:, 1], w_now - dst[:, 0]], 1)
                W, H = H, W
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


class CompositeStream(IterableDataset):
    def __init__(self, seed, split="train", p_multi=0.0, p_occluder=0.0):
        self.seed = seed
        self.split = split
        self.p_multi = p_multi
        self.p_occluder = p_occluder

    def __iter__(self):
        info = get_worker_info()
        wid = info.id if info else 0
        rng = np.random.default_rng(self.seed + 1000 * wid)
        cv2.setNumThreads(1)
        papers, bgs = load_assets()
        pool = papers[self.split]
        while True:
            g, m = make_composite(rng, pool, bgs, p_multi=self.p_multi,
                                  p_occluder=self.p_occluder)
            yield torch.from_numpy(g[None]), torch.from_numpy(m[None])


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
        x = (x.repeat(1, 3, 1, 1) - self.mean) / self.std
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


def fixed_val_set(n, seed=123):
    rng = np.random.default_rng(seed)
    papers, bgs = load_assets()
    xs, ys = [], []
    for _ in range(n):
        g, m = make_composite(rng, papers["val"], bgs)
        xs.append(g[None])
        ys.append(m[None])
    return torch.from_numpy(np.stack(xs)), torch.from_numpy(np.stack(ys))


def onnx_iou(path, vx, vy):
    import onnxruntime as ort

    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    ious = []
    for i in range(len(vx)):
        out = sess.run(None, {sess.get_inputs()[0].name: vx[i:i + 1].numpy()})[0]
        ious.append(iou_score(torch.from_numpy(out), vy[i:i + 1]))
    return float(np.mean(ious))


def preview(n, out_path, p_multi=0.0, p_occluder=0.0):
    rng = np.random.default_rng(1)
    papers, bgs = load_assets()
    tiles = []
    for _ in range(n):
        g, m = make_composite(rng, papers["train"], bgs, p_multi=p_multi, p_occluder=p_occluder)
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
    cv2.imwrite(out_path, sheet)
    print("preview:", out_path)


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
    ap.add_argument("--p-multi", type=float, default=0.0,
                    help="複数枚の紙 (主な 1 枚だけが正解) の割合")
    ap.add_argument("--p-occluder", type=float, default=0.0,
                    help="主な紙の上に小さな紙を載せる割合 (正解は主な紙の四角形全体)")
    ap.add_argument("--init-pth", default="", help="この重みから学習を始める (例: build/paper_seg_v2.pth)")
    args = ap.parse_args()

    if args.preview:
        os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
        preview(args.preview, os.path.join(ROOT, "build", "v2_preview.jpg"),
                p_multi=args.p_multi, p_occluder=args.p_occluder)
        return

    torch.manual_seed(0)
    torch.set_num_threads(args.threads)
    model = PaperSegV2(pretrained=not args.init_pth)
    if args.init_pth:
        model.load_state_dict(torch.load(args.init_pth, map_location="cpu"))
        print("init from", args.init_pth)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"params: {n_params:,} ({n_params * 4 / 1e6:.2f} MB fp32)")

    vx, vy = fixed_val_set(256)
    if os.path.exists(args.baseline):
        print(f"baseline {os.path.basename(args.baseline)} val IoU: {onnx_iou(args.baseline, vx, vy):.4f}")

    loader = DataLoader(CompositeStream(seed=42, p_multi=args.p_multi,
                                        p_occluder=args.p_occluder), batch_size=args.batch,
                        num_workers=args.workers, persistent_workers=args.workers > 0)
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
    torch.onnx.export(model, torch.zeros(1, 1, IMG, IMG), args.out,
                      input_names=["input"], output_names=["output"],
                      opset_version=17, do_constant_folding=True, dynamo=False)
    print(f"exported: {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)")
    print(f"exported val IoU: {onnx_iou(args.out, vx, vy):.4f} (チェックポイント選択に使用)")
    # 選択に使っていない別シードのテストセット。背景素材は学習と共通なので
    # 実写での性能は ./dev.ps1 eval -Data training_data/eval_heldout で測ること。
    tx, ty = fixed_val_set(256, seed=999)
    print(f"exported test IoU: {onnx_iou(args.out, tx, ty):.4f} (未使用シード)")


if __name__ == "__main__":
    main()
