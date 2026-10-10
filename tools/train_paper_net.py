# -*- coding: utf-8 -*-
"""紙面セグメンテーションの超軽量ネット (TinyUNet) を合成データで学習し ONNX へ書き出す。

- 入力: 1ch グレースケール 256x256 (0..1)
- 出力: 1ch ロジット 256x256 (紙マスク)
- データ: ホモグラフィ合成で無限生成 (照明ムラ / 白い背景 / 影 / ノイズ / 枠外はみ出し)
- 用途: Futoji の紙面四隅検出。マスク後処理 (連結成分→凸包→四角形) は
  アプリ側の純 Dart 検出器を再利用する。

使い方:
  python tools/train_paper_net.py            # 学習 + 検証 + assets/models/paper_seg.onnx 出力
  python tools/train_paper_net.py --steps 500  # 短時間の試験学習
"""

import argparse
import math
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

IMG = 256
STEP_MS_BUDGET = None  # 未使用 (ログ用)


# ---------------------------------------------------------------- モデル

class Block(nn.Module):
    def __init__(self, cin, cout):
        super().__init__()
        self.c1 = nn.Conv2d(cin, cout, 3, padding=1)
        self.c2 = nn.Conv2d(cout, cout, 3, padding=1)

    def forward(self, x):
        return F.relu(self.c2(F.relu(self.c1(x))))


class TinyUNet(nn.Module):
    """~380k パラメータの U-Net。fp32 で約 1.5MB。"""

    def __init__(self):
        super().__init__()
        self.e1 = Block(1, 16)
        self.e2 = Block(16, 32)
        self.e3 = Block(32, 64)
        self.e4 = Block(64, 96)
        self.d3 = Block(96 + 64, 64)
        self.d2 = Block(64 + 32, 32)
        self.d1 = Block(32 + 16, 16)
        self.head = nn.Conv2d(16, 1, 1)
        self.pool = nn.MaxPool2d(2)

    def forward(self, x):
        x1 = self.e1(x)
        x2 = self.e2(self.pool(x1))
        x3 = self.e3(self.pool(x2))
        x4 = self.e4(self.pool(x3))
        y3 = self.d3(torch.cat([F.interpolate(x4, scale_factor=2, mode="nearest"), x3], 1))
        y2 = self.d2(torch.cat([F.interpolate(y3, scale_factor=2, mode="nearest"), x2], 1))
        y1 = self.d1(torch.cat([F.interpolate(y2, scale_factor=2, mode="nearest"), x1], 1))
        return self.head(y1)


# ---------------------------------------------------------- 合成データ生成

def solve_homography(src, dst):
    """src[4,2] -> dst[4,2] のホモグラフィ (3x3) を解く。"""
    a = np.zeros((8, 8), dtype=np.float64)
    b = np.zeros(8, dtype=np.float64)
    for i in range(4):
        x, y = src[i]
        u, v = dst[i]
        r0, r1 = i * 2, i * 2 + 1
        a[r0, 0], a[r0, 1], a[r0, 2] = x, y, 1
        a[r0, 6], a[r0, 7] = -u * x, -u * y
        b[r0] = u
        a[r1, 3], a[r1, 4], a[r1, 5] = x, y, 1
        a[r1, 6], a[r1, 7] = -v * x, -v * y
        b[r1] = v
    h = np.linalg.solve(a, b)
    return np.array([[h[0], h[1], h[2]], [h[3], h[4], h[5]], [h[6], h[7], 1.0]])


def smooth_noise(rng, h, w, cells, amp):
    """ブロックノイズを bilinear 風に拡大した滑らかなノイズ。"""
    small = rng.uniform(0, 1, (max(2, h // cells), max(2, w // cells)))
    ys = np.linspace(0, small.shape[0] - 1, h)
    xs = np.linspace(0, small.shape[1] - 1, w)
    y0 = np.floor(ys).astype(int)
    x0 = np.floor(xs).astype(int)
    y1 = np.clip(y0 + 1, 0, small.shape[0] - 1)
    x1 = np.clip(x0 + 1, 0, small.shape[0] - 1)
    fy = (ys - y0)[:, None]
    fx = (xs - x0)[None, :]
    top = small[y0][:, x0] * (1 - fx) + small[y0][:, x1] * fx
    bot = small[y1][:, x0] * (1 - fx) + small[y1][:, x1] * fx
    return top + (bot - top) * fy


def make_sample(rng, img=IMG):
    """1 サンプル (画像 [1,H,W] 0..1, マスク [1,H,W] 0/1) を生成する。"""
    # ---- 背景: 暗い机〜明るい机まで。白い矩形 (雑巾的な明部) を混ぜる ----
    bright_bg = rng.random() < 0.3
    base = rng.uniform(0.55, 0.85) if bright_bg else rng.uniform(0.05, 0.45)
    img2d = np.full((img, img), base, dtype=np.float32)
    img2d += smooth_noise(rng, img, img, int(rng.integers(4, 12)), 1) * rng.uniform(0.03, 0.12)
    # 全体の照明ムラ (グラデーション)
    angle = rng.uniform(0, 2 * np.pi)
    yy, xx = np.mgrid[0:img, 0:img].astype(np.float32)
    grad = (np.cos(angle) * xx + np.sin(angle) * yy) / img
    img2d += (grad - 0.5) * rng.uniform(0.05, 0.25)
    # 背景の物体 (矩形) を数個
    for _ in range(int(rng.integers(0, 4))):
        w = int(rng.integers(10, img // 2))
        h = int(rng.integers(10, img // 2))
        x0 = int(rng.integers(0, img - w))
        y0 = int(rng.integers(0, img - h))
        v = np.clip(base + rng.uniform(-0.35, 0.35), 0, 1)
        img2d[y0:y0 + h, x0:x0 + w] = v
    img2d += rng.normal(0, rng.uniform(0.01, 0.04), (img, img)).astype(np.float32)

    # ---- 紙の四角形 (単位正方形) を画像へ射影 ----
    # 4*hw*hh = 面積 になるようアスペクト比 r から半辺長を決める
    area_target = rng.uniform(0.10, 0.65)
    r = rng.uniform(0.6, 1.7)
    if rng.random() < 0.5:
        r = 1 / r
    hw = math.sqrt(area_target / (4 * r))
    hh = r * hw
    cx, cy = rng.uniform(0.2, 0.8), rng.uniform(0.2, 0.8)
    corners = np.array([
        [cx - hw, cy - hh], [cx + hw, cy - hh], [cx + hw, cy + hh], [cx - hw, cy + hh],
    ], dtype=np.float64)
    jitter = rng.uniform(0.0, 0.14, size=(4, 2)) * np.where(rng.random((4, 2)) < 0.5, -1, 1)
    corners += jitter  # はみ出しも許容 (クリップは描画側で自然に起こる)
    corners *= img  # 正規化座標 -> ピクセル座標系 (画像グリッドと同じ系で解く)

    H = solve_homography(np.array([[0, 0], [1, 0], [1, 1], [0, 1]], dtype=np.float64), corners)
    Hinv = np.linalg.inv(H)
    ys, xs = np.mgrid[0:img, 0:img].astype(np.float64)
    ones = np.ones_like(xs)
    pix = np.stack([xs, ys, ones], axis=0).reshape(3, -1)  # 3 x N
    src = Hinv @ pix
    sx = src[0] / np.maximum(src[2], 1e-9)
    sy = src[1] / np.maximum(src[2], 1e-9)
    inside = (sx >= 0) & (sx <= 1) & (sy >= 0) & (sy <= 1)
    mask = inside.reshape(img, img).astype(np.float32)

    # ---- 紙の中身: 明るい白 + 譜線/文字っぽいパターン + 紙の上の照明ムラ ----
    paper_val = rng.uniform(0.62, 0.95)
    tex = np.full(img * img, paper_val, dtype=np.float32)
    r = rng.random()
    if r < 0.55:
        # 擬似文字: 行状に並ぶ小さな暗い塊 (実写の印刷を模倣)
        tx = sx.copy()
        ty = sy.copy()
        # ページ内座標 (0..1) を行・列に量子化して文字を置く
        rows = rng.integers(6, 16)
        cols = rng.integers(8, 24)
        cell_h = 1.0 / rows
        cell_w = 1.0 / cols
        row_idx = np.floor(ty / cell_h).astype(int)
        col_idx = np.floor(tx / cell_w).astype(int)
        rng_rows = np.random.default_rng(rng.integers(0, 1 << 30))
        dark = rng.uniform(0.25, 0.65)
        # 各セルに塊を置くかどうか (密度 40-80%)
        has = rng_rows.random((rows, cols)) < rng.uniform(0.4, 0.85)
        # セル内の塊の大きさ・位置も乱数 (簡易: セル中央の帯)
        in_row = (ty - row_idx * cell_h) > cell_h * 0.25
        in_col = np.abs((tx - col_idx * cell_w) - cell_w * 0.5) < cell_w * rng.uniform(0.25, 0.45)
        txt = (in_row & in_col & has[np.clip(row_idx, 0, rows - 1),
                                     np.clip(col_idx, 0, cols - 1)])
        tex[txt] -= rng.uniform(0.35, 0.6)
    elif r < 0.8:
        # 譜線 (五線譜っぽい平行線)
        freq = rng.integers(8, 20)
        phase = rng.uniform(0, 1)
        lines = np.abs((sy * freq + phase) % 1.0 - 0.5) < 0.12
        tex[lines] -= rng.uniform(0.3, 0.55)
    else:
        # 大きな図形ブロック (写真・図)
        bx0, by0 = rng.uniform(0.1, 0.5), rng.uniform(0.1, 0.5)
        bw, bh = rng.uniform(0.15, 0.4), rng.uniform(0.15, 0.4)
        block = (sx > bx0) & (sx < bx0 + bw) & (sy > by0) & (sy < by0 + bh)
        tex[block] -= rng.uniform(0.35, 0.6)
    tex += rng.normal(0, 0.03, tex.shape).astype(np.float32)
    tex2d = tex.reshape(img, img)
    if rng.random() < 0.6:
        # 紙の上の影 (片側が暗い)
        a2 = rng.uniform(0, 2 * np.pi)
        shade = (np.cos(a2) * xx + np.sin(a2) * yy) / img
        tex2d -= (shade - shade[mask == 1].mean() if mask.sum() > 0 else shade - 0.5) * rng.uniform(0.05, 0.3)
    img2d = np.where(mask == 1, tex2d, img2d)

    # ---- 紙のドロップシャドウ (周辺をわずかに暗く) ----
    m = torch.from_numpy(mask)[None, None].float()
    dil = m
    for _ in range(3):
        dil = F.max_pool2d(dil, 3, stride=1, padding=1)
    halo = (dil[0, 0].numpy() - mask)
    img2d -= halo * rng.uniform(0.1, 0.35)

    img2d = np.clip(img2d, 0, 1)
    return img2d[None, :].astype(np.float32), mask[None, :].astype(np.float32)


def make_batch(n, rng):
    xs = np.empty((n, 1, IMG, IMG), dtype=np.float32)
    ys = np.empty((n, 1, IMG, IMG), dtype=np.float32)
    for i in range(n):
        xs[i], ys[i] = make_sample(rng)
    return torch.from_numpy(xs), torch.from_numpy(ys)


# ------------------------------------------------ 実データ (擬似ラベル)

def load_real_dataset(images_dir, masks_dir, size=IMG):
    """training_data の画像+教師マスクを 256x256 に縮小して読み込む。"""
    from PIL import Image

    xs, ys, ids = [], [], []
    files = sorted(
        f for f in os.listdir(masks_dir) if f.endswith("_mask.png")
    )
    for f in files:
        stem = f[: -len("_mask.png")]
        img_path = os.path.join(images_dir, stem + ".png")
        mask_path = os.path.join(masks_dir, f)
        if not os.path.exists(img_path):
            continue
        im = Image.open(img_path).convert("L").resize(
            (size, size), Image.BILINEAR
        )
        mk = Image.open(mask_path).convert("L").resize(
            (size, size), Image.BILINEAR
        )
        xs.append(np.asarray(im, dtype=np.float32)[None] / 255.0)
        ys.append(
            (np.asarray(mk, dtype=np.float32) / 255.0 > 0.5)[None].astype(np.float32)
        )
        ids.append(stem)
    return np.stack(xs), np.stack(ys), ids


def augment_real(x, y, rng):
    """実サンプル 1 枚に軽い幾何/光度拡張を適用する (in-place のため copy 済み)。"""
    img_size = x.shape[-1]
    # ランダムスケール + シフト
    scale = rng.uniform(0.75, 1.15)
    shx = rng.uniform(-0.12, 0.12)
    shy = rng.uniform(-0.12, 0.12)
    t = torch.from_numpy(x[None])
    grid = torch.empty(1, img_size, img_size, 2)
    ys_ = torch.linspace(-1, 1, img_size)
    xs_ = torch.linspace(-1, 1, img_size)
    gy, gx = torch.meshgrid(ys_, xs_, indexing="ij")
    grid[..., 0] = (gx + shx) / scale
    grid[..., 1] = (gy + shy) / scale
    xt = F.grid_sample(t, grid, align_corners=False, padding_mode="zeros")
    yt = F.grid_sample(torch.from_numpy(y[None]), grid, align_corners=False,
                       padding_mode="zeros")
    # 光度
    xout = xt[0].numpy()
    xout = xout * rng.uniform(0.75, 1.3) + rng.uniform(-0.12, 0.12)
    xout += rng.normal(0, rng.uniform(0.0, 0.05), xout.shape).astype(np.float32)
    xout = np.clip(xout, 0, 1)
    yout = (yt[0].numpy() > 0.5).astype(np.float32)
    return xout, yout


def make_mixed_batch(real_x, real_y, n, rng, real_ratio=0.5):
    """実データと合成データを混ぜたバッチを作る。"""
    xs = np.empty((n, 1, IMG, IMG), dtype=np.float32)
    ys = np.empty((n, 1, IMG, IMG), dtype=np.float32)
    n_real = min(len(real_x), int(round(n * real_ratio)))
    idxs = rng.permutation(len(real_x))[:n_real]
    for k, i in enumerate(idxs):
        x, y = augment_real(real_x[i], real_y[i], rng)
        xs[k], ys[k] = x, y
    while n_real < n:
        xs[n_real], ys[n_real] = make_sample(rng)
        n_real += 1
    order = rng.permutation(n)
    return torch.from_numpy(xs[order]), torch.from_numpy(ys[order])


# ---------------------------------------------------------------- 学習

def iou_score(logits, targets, thresh=0.5):
    pred = (torch.sigmoid(logits) > thresh).float()
    inter = (pred * targets).sum()
    union = ((pred + targets) > 0).float().sum()
    return (inter / union).item() if union > 0 else 1.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", type=int, default=3000)
    ap.add_argument("--batch", type=int, default=16)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--out", default="assets/models/paper_seg.onnx")
    ap.add_argument("--real-data", default=os.path.join(HERE, "..", "training_data", "paper_photos"),
                    help="images/ と masks/ を含むディレクトリ (擬似ラベル)")
    ap.add_argument("--save-pth", action="store_true", help="torch 重みも保存する")
    ap.add_argument("--init-pth", default="", help="学習済み .pth から重みを初期化する")
    ap.add_argument("--hard-stems", default="", help="重点学習する画像ID一覧ファイル (1行1ID, 5倍に複製)")
    ap.add_argument("--real-ratio", type=float, default=0.5)
    args = ap.parse_args()

    torch.manual_seed(39)
    rng = np.random.default_rng(39)
    torch.set_num_threads(8)  # 12 スレッドはかえって遅い (実測)

    model = TinyUNet()
    if args.init_pth:
        model.load_state_dict(torch.load(args.init_pth, map_location="cpu"))
        print(f"initialized from {args.init_pth}")
    n_params = sum(p.numel() for p in model.parameters())
    print(f"params: {n_params:,} ({n_params * 4 / 1e6:.2f} MB fp32)")
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.steps)
    bce = nn.BCEWithLogitsLoss()

    # 実データ (擬似ラベル) を読み込み、180/20 に分割
    real_x = real_y = real_ids = None
    val_real_x = val_real_y = None
    img_dir = os.path.join(args.real_data, "images")
    mask_dir = os.path.join(args.real_data, "masks")
    if os.path.isdir(mask_dir):
        rx, ry, rids = load_real_dataset(img_dir, mask_dir)
        rng2 = np.random.default_rng(77)
        order = rng2.permutation(len(rx))
        n_val = max(8, len(rx) // 10)
        val_idx, train_idx = order[:n_val], order[n_val:]
        real_x, real_y = rx[train_idx], ry[train_idx]
        val_real_x, val_real_y = rx[val_idx], ry[val_idx]
        # ハードサンプル (失敗画像) を 5 倍に複製して重点学習
        if args.hard_stems and os.path.exists(args.hard_stems):
            hard = [l.strip() for l in open(args.hard_stems, encoding="utf-8") if l.strip()]
            id_to_idx = {rid: i for i, rid in enumerate(rids)}
            hard_train = [id_to_idx[h] for h in hard if h in id_to_idx
                          and id_to_idx[h] in set(train_idx.tolist())]
            if hard_train:
                dup = np.concatenate([train_idx, np.repeat(hard_train, 4)])
                real_x, real_y = rx[dup], ry[dup]
                print(f"hard oversample: +{len(hard_train) * 4} samples")
        print(f"real data: train={len(real_x)} val={len(val_real_x)}")
    else:
        print("no real data dir; synthetic only")

    t0 = time.time()
    running = 0.0
    for step in range(1, args.steps + 1):
        if real_x is not None:
            x, y = make_mixed_batch(real_x, real_y, args.batch, rng,
                                    real_ratio=max(0.0, min(1.0, args.real_ratio)))
        else:
            x, y = make_batch(args.batch, rng)
        opt.zero_grad()
        logits = model(x)
        loss = bce(logits, y)
        loss.backward()
        opt.step()
        sched.step()
        running += loss.item()
        if step % 200 == 0:
            with torch.no_grad():
                vx, vy = make_batch(32, rng)
                iou = iou_score(model(vx), vy)
                msg = f"step {step:5d}/{args.steps} loss {running / 200:.4f} syn_iou {iou:.4f}"
                if val_real_x is not None:
                    r_iou = iou_score(model(torch.from_numpy(val_real_x)),
                                      torch.from_numpy(val_real_y))
                    msg += f" real_iou {r_iou:.4f}"
                print(msg + f" ({(time.time() - t0):.0f}s)", flush=True)
            running = 0.0

    # ---- 最終検証 ----
    model.eval()
    with torch.no_grad():
        ious = []
        for _ in range(10):
            vx, vy = make_batch(64, rng)
            ious.append(iou_score(model(vx), vy))
    print(f"final synthetic val IoU: {np.mean(ious):.4f} (n=640)")
    if val_real_x is not None:
        with torch.no_grad():
            r_iou = iou_score(model(torch.from_numpy(val_real_x)),
                              torch.from_numpy(val_real_y))
        print(f"final real val IoU: {r_iou:.4f} (n={len(val_real_x)})")

    if args.save_pth:
        torch.save(model.state_dict(), args.out[:-5] + ".pth")
        print("saved state_dict:", args.out[:-5] + ".pth")

    # ---- ONNX エクスポート ----
    dummy = torch.zeros(1, 1, IMG, IMG)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    torch.onnx.export(
        model, dummy, args.out,
        input_names=["input"], output_names=["output"],
        opset_version=13, do_constant_folding=True, dynamo=False,
    )
    size = os.path.getsize(args.out)
    print(f"exported: {args.out} ({size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
