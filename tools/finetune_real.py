# -*- coding: utf-8 -*-
"""実キャプチャ (ユーザーの実撮影シーン) で TinyUNet をファインチューニングする。

- 紙ありキャプチャ: BiRefNet 教師マスクを使用
- 紙なしキャプチャ: 空マスク (ウェブカメラ等は紙ではないと学習させる)
- 生成画像 200 枚 (BiRefNet 擬似マスク) + 合成データも混合して退化を防ぐ

使い方:
  python tools/finetune_real.py                 # 学習 + 評価 + assets に ONNX 出力
"""

import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image

from train_paper_net import (TinyUNet, make_sample, make_batch, iou_score,
                             load_real_dataset, augment_real)

IMG = 256

# トリアージ済み: 紙が写っているキャプチャ (BiRefNet マスク使用)
PAPER_CAPTURES = [
    'CAP2807639686690776350.jpg',
    'CAP3333354730965744561.jpg',
    'CAP6803204912898649751.jpg',
]
# 紙なしキャプチャ (空マスクで「紙ではない」を学習させる)
NOPAPER_CAPTURES = [
    'CAP1139552104731981368.jpg',
    'CAP1643449497185691480.jpg',
    'CAP2935795320092052890.jpg',
    'CAP3544581474585362157.jpg',
    'CAP4181161822592414060.jpg',
    'CAP6522108627461954465.jpg',
    'CAP7587149781016318692.jpg',
    'CAP7711862106954049172.jpg',
]


def load_captures(cap_dir, size=IMG):
    """実キャプチャ → (グレー 0..1, マスク 0/1) ペア。"""
    xs, ys = [], []
    for f in PAPER_CAPTURES:
        p = os.path.join(cap_dir, f)
        if not os.path.exists(p):
            continue
        im = Image.open(p).convert('L').resize((size, size), Image.BILINEAR)
        xs.append(np.asarray(im, dtype=np.float32)[None] / 255.0)
        mp = os.path.join(cap_dir, 'masks', f[:-4] + '_mask.png')
        mk = Image.open(mp).convert('L').resize((size, size), Image.BILINEAR)
        ys.append((np.asarray(mk, dtype=np.float32) / 255.0 > 0.5)[None].astype(np.float32))
    for f in NOPAPER_CAPTURES:
        p = os.path.join(cap_dir, f)
        if not os.path.exists(p):
            continue
        im = Image.open(p).convert('L').resize((size, size), Image.BILINEAR)
        xs.append(np.asarray(im, dtype=np.float32)[None] / 255.0)
        ys.append(np.zeros((1, size, size), dtype=np.float32))
    return np.stack(xs), np.stack(ys)


def make_mixed_batch(cap_x, cap_y, gen_x, gen_y, n, rng, cap_ratio=0.35,
                     gen_ratio=0.25):
    """キャプチャ (重点) + 生成画像 + 合成 の混合バッチ。"""
    xs = np.empty((n, 1, IMG, IMG), dtype=np.float32)
    ys = np.empty((n, 1, IMG, IMG), dtype=np.float32)
    n_cap = min(len(cap_x), int(round(n * cap_ratio)))
    n_gen = min(len(gen_x), int(round(n * gen_ratio)))
    cap_idxs = rng.integers(0, len(cap_x), n_cap)
    for k, i in enumerate(cap_idxs):
        xs[k], ys[k] = augment_real(cap_x[i], cap_y[i], rng)
    gen_idxs = rng.integers(0, len(gen_x), n_gen)
    for k, i in enumerate(gen_idxs, start=n_cap):
        xs[k], ys[k] = augment_real(gen_x[i], gen_y[i], rng)
    for k in range(n_cap + n_gen, n):
        xs[k], ys[k] = make_sample(rng)
    order = rng.permutation(n)
    return torch.from_numpy(xs[order]), torch.from_numpy(ys[order])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--steps', type=int, default=1500)
    ap.add_argument('--batch', type=int, default=12)
    ap.add_argument('--lr', type=float, default=3e-4)
    ap.add_argument('--init-pth', default=os.path.join(
        HERE, '..', 'assets', 'models', 'paper_seg.pth'))
    ap.add_argument('--out', default=os.path.join(
        HERE, '..', 'assets', 'models', 'paper_seg.onnx'))
    ap.add_argument('--cap-dir', default=os.path.join(HERE, 'real_captures'))
    ap.add_argument('--gen-dir', default=os.path.join(
        HERE, '..', 'training_data', 'paper_photos'))
    args = ap.parse_args()

    rng = np.random.default_rng(55)
    torch.manual_seed(55)
    torch.set_num_threads(8)

    model = TinyUNet()
    if args.init_pth and os.path.exists(args.init_pth):
        model.load_state_dict(torch.load(args.init_pth, map_location='cpu'))
        print(f'initialized from {args.init_pth}')
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=args.steps)
    bce = nn.BCEWithLogitsLoss()

    cap_x, cap_y = load_captures(args.cap_dir)
    print(f'captures: {len(cap_x)} (paper {len(PAPER_CAPTURES)} / nopaper {len(NOPAPER_CAPTURES)})')

    gen_x = gen_y = None
    img_dir = os.path.join(args.gen_dir, 'images')
    mask_dir = os.path.join(args.gen_dir, 'masks')
    if os.path.isdir(mask_dir):
        gen_x, gen_y, _ = load_real_dataset(img_dir, mask_dir)
        print(f'generated: {len(gen_x)}')

    t0 = time.time()
    running = 0.0
    for step in range(1, args.steps + 1):
        x, y = make_mixed_batch(cap_x, cap_y, gen_x, gen_y, args.batch, rng)
        opt.zero_grad()
        logits = model(x)
        loss = bce(logits, y)
        loss.backward()
        opt.step()
        sched.step()
        running += loss.item()
        if step % 200 == 0:
            with torch.no_grad():
                cap_iou = iou_score(model(torch.from_numpy(cap_x)),
                                    torch.from_numpy(cap_y))
                msg = (f'step {step:5d}/{args.steps} loss {running / 200:.4f} '
                       f'cap_iou {cap_iou:.4f}')
                if gen_x is not None:
                    sub = rng.permutation(len(gen_x))[:32]
                    g_iou = iou_score(model(torch.from_numpy(gen_x[sub])),
                                      torch.from_numpy(gen_y[sub]))
                    msg += f' gen_iou {g_iou:.4f}'
                print(msg + f' ({(time.time() - t0):.0f}s)', flush=True)
            running = 0.0

    model.eval()
    with torch.no_grad():
        cap_iou = iou_score(model(torch.from_numpy(cap_x)),
                            torch.from_numpy(cap_y))
        # 紙なしキャプチャ: マスク面積が 5% 未満であることを確認
        nopaper_ok = 0
        nopaper_x = np.stack([
            np.asarray(Image.open(os.path.join(args.cap_dir, f)).convert('L')
                       .resize((IMG, IMG), Image.BILINEAR), dtype=np.float32)[None] / 255.0
            for f in NOPAPER_CAPTURES if os.path.exists(os.path.join(args.cap_dir, f))
        ])
        pred = (torch.sigmoid(model(torch.from_numpy(nopaper_x))) > 0.5).float()
        for i in range(len(nopaper_x)):
            fill = float(pred[i].mean())
            nopaper_ok += fill < 0.05
        print(f'FINAL cap IoU: {cap_iou:.4f} | nopaper reject: {nopaper_ok}/{len(nopaper_x)}')

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    dummy = torch.zeros(1, 1, IMG, IMG)
    torch.onnx.export(
        model, dummy, args.out,
        input_names=['input'], output_names=['output'],
        opset_version=13, do_constant_folding=True, dynamo=False,
    )
    pth_out = args.out[:-5] + '.pth'
    torch.save(model.state_dict(), pth_out)
    print(f'exported: {args.out} ({os.path.getsize(args.out) / 1024:.0f} KB)')
    print(f'saved state_dict: {pth_out}')


if __name__ == '__main__':
    main()
