# -*- coding: utf-8 -*-
"""五線を手がかりにした紙面の歪み (湾曲) 補正の試作。

アプリの台形補正 (lib/services/warper.dart のホモグラフィ) の後段に置く想定。
五線は「本来まっすぐ水平」なので、検出した線の曲がりから縦方向の変位場
D(x, y) を推定し、y_src = y + D(x, y) で再サンプリングする。

  1. 台形補正 (四隅ラベルからホモグラフィ、幅 1200px)
  2. 二値化し、縦の連なりの最頻値から五線の太さと間隔を求める
  3. 縦の短冊ごとに五線 (5 本の櫛) を検出し、短冊間をつないで線ごとの点列にする
     (詳細は detect_lines)
  4. D(x, y) = Σ c_ab x^a y^b (a=1..6, b=0..2, 正規化座標) を最小二乗で当てはめる。
     各線のまっすぐな高さ t_i は未知なので、t_i と係数を交互に更新する。
     x を含まない項は t_i と区別できないので基底から外す。
  5. cv2.remap で再サンプリング (2〜4 を 2 回反復、写像は合成)

横方向の縮み (ノド付近の圧縮) は扱わない (縦方向の変位のみ)。
五線が少ないページ (表紙・歌詞のみ) は補正しない (線が MIN_LINES 未満で恒等)。

評価:
  - 実写: training_data/eval_hard の四隅ラベルで台形補正した画像に適用
  - 合成: 台形補正済み画像に既知の湾曲 (ノド側が反る形) をかけ、補正で戻るか
  指標は「検出した各線の曲がり」= 線ごとの当てはめ曲線の (max - min) [px] の中央値。

使い方:
  tools/.venv/Scripts/python tools/dewarp_staff.py
出力: build/dewarp/<name>.jpg (左: 補正前 / 右: 補正後、検出線を重ねる) と標準出力の表
"""

import argparse
import glob
import json
import os

import cv2
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")

WIDTH = 1200
MIN_LINES = 5
DEG_X, DEG_Y = 6, 2


def rectify(img, corners):
    """四隅 (正規化座標, 左上から時計回り) で台形補正する。"""
    h, w = img.shape[:2]
    src = np.float32([[x * w, y * h] for x, y in corners])
    top = np.linalg.norm(src[1] - src[0])
    bottom = np.linalg.norm(src[2] - src[3])
    left = np.linalg.norm(src[3] - src[0])
    right = np.linalg.norm(src[2] - src[1])
    aspect = (left + right) / max(top + bottom, 1)
    W, H = WIDTH, round(WIDTH * aspect)
    dst = np.float32([[0, 0], [W - 1, 0], [W - 1, H - 1], [0, H - 1]])
    m = cv2.getPerspectiveTransform(src, dst)
    return cv2.warpPerspective(img, m, (W, H), flags=cv2.INTER_LINEAR,
                               borderMode=cv2.BORDER_REPLICATE)


def run_lengths(ink):
    """縦方向の (黒の連なり, 白の連なり) の長さの配列。"""
    m = (ink > 0).astype(np.int8)
    d = np.diff(np.pad(m, ((1, 1), (0, 0))), axis=0).T  # (W, H+1)
    col, pos = np.nonzero(d)
    val = d[col, pos]
    black = pos[1:][(val[:-1] == 1) & (col[1:] == col[:-1])] - pos[:-1][(val[:-1] == 1) & (col[1:] == col[:-1])]
    white = pos[1:][(val[:-1] == -1) & (col[1:] == col[:-1])] - pos[:-1][(val[:-1] == -1) & (col[1:] == col[:-1])]
    return black, white


def staff_metrics(ink):
    """五線の太さ t と線間隔 sp (線の中心どうし, px) を連なりの最頻値から求める。"""
    black, white = run_lengths(ink)
    t = int(np.bincount(black[black < 12]).argmax()) if black.size else 2
    w = white[(white > t) & (white < 60)]
    gap = int(np.bincount(w).argmax()) if w.size else 8
    return max(t, 1), float(gap + t)


def _strip_profile(strip, slopes):
    """短冊を各傾きでずらしながら横方向に足し合わせた投影。最も鋭いものを返す。"""
    h, w = strip.shape
    xc = (w - 1) / 2
    best = None
    for s in slopes:
        shift = np.round(s * (np.arange(w) - xc)).astype(int)
        p = np.zeros(h, np.float32)
        for x in range(w):
            p += np.roll(strip[:, x], -shift[x])
        score = float((p * p).sum())
        if best is None or score > best[0]:
            best = (score, s, p)
    return best[1], best[2]


def detect_lines(gray, return_staffs=False):
    """五線を検出し、線ごとの点列 [(xs, ys), ...] を返す (各五線の 5 本)。

    1. 縦の短冊 (幅 ~W/24、半分ずつ重ねる) ごとに、傾きを振って横投影し最も鋭い投影をとる
    2. 投影上で「sp 間隔で 5 本そろう櫛」のスコアが高い位置を五線とする
       (5 本の投影値の下から 2 番目 = 1 本欠けても許すが、スラー・連桁は櫛にならない)
    3. 短冊間を左から右へ、傾きで予測した y の近い五線どうしでつなぐ
    4. 横幅の 1/4 以上つながった五線だけを採用
    """
    H, W = gray.shape
    ink = cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_MEAN_C,
                                cv2.THRESH_BINARY_INV, 31, 12)
    t, sp = staff_metrics(ink)
    inkf = (ink > 0).astype(np.float32)
    sw = max(40, W // 24)
    slopes = np.linspace(-0.2, 0.2, 17)
    det = []  # (xc, slope, [5 本の y])
    for x0 in range(0, W - sw + 1, sw // 2):
        s, p = _strip_profile(inkf[:, x0:x0 + sw], slopes)
        p = cv2.blur(p.reshape(-1, 1), (1, t + 1)).ravel() * (t + 1)  # 太さぶんまとめる
        pm = np.maximum.reduce([np.roll(p, k) for k in (-1, 0, 1)])  # ±1px の揺れを許す
        ks = np.arange(-2, 3)
        gs = np.arange(-1.5, 2)  # 線と線の間 (4 か所)
        lidx = np.arange(H)[:, None] + np.round(ks * sp).astype(int)[None, :]
        gidx = np.arange(H)[:, None] + np.round(gs * sp).astype(int)[None, :]
        valid = (lidx[:, 0] >= 0) & (lidx[:, -1] < H)
        lv = pm[np.clip(lidx, 0, H - 1)]
        gv = p[np.clip(gidx, 0, H - 1)]
        # 5 本すべてに線があり、間は空いている。1 本ずれた位置では「線」の 1 つが
        # 間に当たるので最小値が落ちる。
        # 表の罫線 (等間隔に何本も続く) を落とす: 五線の外側 ±3 間隔の位置は空いている
        oidx = np.arange(H)[:, None] + np.round(np.array([-3, 3]) * sp).astype(int)[None, :]
        ov = pm[np.clip(oidx, 0, H - 1)].max(axis=1)
        comb = np.where(valid & (gv.mean(axis=1) < lv.mean(axis=1) / 3) & (ov < lv.mean(axis=1) / 2),
                        np.minimum(lv.min(axis=1), lv.mean(axis=1) - gv.mean(axis=1)), 0)
        thr = 0.35 * sw * t
        y = 0
        order = np.argsort(-comb)
        taken = np.zeros(H, bool)
        for yc in order:
            if comb[yc] < thr:
                break
            if taken[yc]:
                continue
            lo, hi = max(0, int(yc - 2.5 * sp)), min(H, int(yc + 2.5 * sp) + 1)
            taken[lo:hi] = True
            ys = []
            for k in ks:  # 各線を ±t の範囲で投影の重心に寄せる
                c = int(round(yc + k * sp))
                a, b = max(0, c - t - 1), min(H, c + t + 2)
                w_ = p[a:b]
                ys.append(float((w_ * np.arange(a, b)).sum() / max(w_.sum(), 1e-6)))
            det.append((x0 + (sw - 1) / 2, s, ys))
    # 短冊をまたいでつなぐ
    det.sort(key=lambda d: d[0])
    tracks = []  # [[(xc, slope, ys), ...], ...]
    for d in det:
        best, bd = None, 0.8 * sp
        for tr in tracks:
            lx, ls, lys = tr[-1]
            if lx >= d[0] or d[0] - lx > 4 * sw:
                continue
            pred = lys[2] + 0.5 * (ls + d[1]) * (d[0] - lx)
            e = abs(pred - d[2][2])
            if e < bd:
                best, bd = tr, e
        if best is None:
            tracks.append([d])
        else:
            best.append(d)
    # 同じ五線の上に重なったトラック (検出が 1 本ずれた区間) は長いほうを残す
    tracks.sort(key=len, reverse=True)
    kept = []
    for tr in tracks:
        xs = np.array([d[0] for d in tr])
        y2 = np.array([d[2][2] for d in tr])
        dup = False
        for kx, ky in kept:
            lo, hi = max(xs.min(), kx.min()), min(xs.max(), kx.max())
            if hi < lo:
                continue
            if abs(np.interp((lo + hi) / 2, xs, y2) - np.interp((lo + hi) / 2, kx, ky)) < 2.5 * sp:
                dup = True
                break
        if not dup:
            kept.append((xs, y2))
    keep_ids = {id(tr) for tr in tracks if any(tr[0][0] == kx[0] and tr[0][2][2] == ky[0] for kx, ky in kept)}
    lines = []
    staffs = []
    for tr in tracks:
        if id(tr) not in keep_ids:
            continue
        xs = np.array([d[0] for d in tr])
        span = xs.max() - xs.min()
        # 横幅の 1/4 以上、かつ範囲内の短冊の半分以上で見つかっていること
        if span < 0.25 * W or len(xs) < 0.5 * (span / (sw // 2) + 1):
            continue
        ys5 = np.array([d[2] for d in tr])
        staffs.append((xs, ys5))
        for k in range(5):
            lines.append((xs.astype(np.float64), ys5[:, k].astype(np.float64)))
    return (lines, staffs) if return_staffs else lines


def _basis(x, y, deg_y=DEG_Y):
    return np.stack([x ** a * y ** b for a in range(1, DEG_X + 1) for b in range(deg_y + 1)], axis=-1)


def fit_field(lines, W, H, iters=4, deg_y=DEG_Y):
    """各線の観測 y = t_i + D(x, t_i) となる D の係数を求める。"""
    if len(lines) < MIN_LINES:
        return None  # 五線が少ないページは補正しない
    xs = [l[0] / W for l in lines]
    ys = [l[1] / H for l in lines]
    t = np.array([np.median(y) for y in ys])
    coef = None
    w = None
    for _ in range(iters):
        A = np.concatenate([_basis(x, np.full_like(x, ti), deg_y) for x, ti in zip(xs, t)])
        b = np.concatenate([y - ti for y, ti in zip(ys, t)])
        if coef is not None:
            # 外れ点 (検出ミス) を落とす: 残差が残差の中央値の 6 倍 (かつ 3px)を超える点の重みを 0 に
            r = np.abs(A @ coef - b)
            w = (r < max(6 * np.median(r), 3.0 / H)).astype(np.float64)
        sw_ = np.ones_like(b) if w is None else w
        coef, *_ = np.linalg.lstsq(A * sw_[:, None], b * sw_, rcond=None)
        t = np.array([np.median(y - _basis(x, np.full_like(x, ti), deg_y) @ coef)
                      for x, y, ti in zip(xs, ys, t)])
    y_lo, y_hi = t.min(), t.max()
    if deg_y > 0 and y_hi - y_lo < 0.3:
        # 線が縦の狭い範囲にしかない: y 方向の変化は推定できないので x だけの変位にする
        return fit_field(lines, W, H, iters, deg_y=0)
    xa = np.concatenate(xs)
    # 安全策: 変位がページ高さの 12% を超える補正は誤検出とみなす
    gxs, gys = np.meshgrid(np.linspace(xa.min(), xa.max(), 30), np.linspace(y_lo, y_hi, 30))
    if np.abs(_basis(gxs, gys, deg_y) @ coef).max() > 0.12:
        return None
    return coef, deg_y, (xa.min(), xa.max()), (y_lo, y_hi)


def field_map(shape, field):
    """補正後 (x, y) → 補正前 y の写像 (float32 の map_y)。"""
    H, W = shape[:2]
    gx, gy = np.meshgrid(np.arange(W, dtype=np.float32), np.arange(H, dtype=np.float32))
    if field is None:
        return gx, gy
    coef, deg_y, (x_lo, x_hi), (y_lo, y_hi) = field
    # 線のない端は最寄りの検出範囲の変位を延長する (高次多項式の外挿で暴れないように)
    d = _basis(np.clip(gx / W, x_lo, x_hi), np.clip(gy / H, y_lo, y_hi), deg_y) @ coef
    return gx, (gy + d * H).astype(np.float32)


def dewarp(img, passes=2):
    """検出 → 当てはめ → 再サンプリングを繰り返す (急な曲がりは 1 回では拾い切れないため)。

    写像は合成して元画像から 1 回だけ再サンプリングする (ぼけを重ねない)。
    """
    gray0 = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
    gx, map_y = field_map(gray0.shape, None)
    first_lines, fitted = None, False
    cur = gray0
    for _ in range(passes):
        lines = detect_lines(cur)
        if first_lines is None:
            first_lines = lines
        field = fit_field(lines, cur.shape[1], cur.shape[0])
        if field is None:
            break
        _, my = field_map(cur.shape, field)
        # 新しい写像: 出力 (x, y) → 現在画像の (x, my) → 元画像の (x, map_y(x, my))
        new_map = cv2.remap(map_y, gx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        nxt = cv2.remap(gray0, gx, new_map, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        # 安全策: 補正後に検出し直して曲がりが減っていなければ、この回の補正は捨てる
        if not bend(detect_lines(nxt)) < 0.8 * bend(lines):
            break
        fitted = True
        map_y, cur = new_map, nxt
    out = cv2.remap(img, gx, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    return out, first_lines, fitted


def bend(lines):
    """各線の曲がり (当てはめ曲線の max-min, px) の中央値。"""
    if not lines:
        return float("nan")
    v = []
    for xs, ys in lines:
        p = np.polyfit(xs, ys, min(3, len(xs) - 1))
        f = np.polyval(p, np.linspace(xs.min(), xs.max(), 50))
        v.append(f.max() - f.min())
    return float(np.median(v))


def synth_curl(img, amp=0.035, squeeze=0.05, spine_left=True):
    """ノド側が反った見開きページを模した湾曲をかける。

    ノド (片側の縁) に近いほど線が上下中央から離れる向きに曲がり、横にも縮む。
    """
    H, W = img.shape[:2]
    gx, gy = np.meshgrid(np.arange(W, dtype=np.float32), np.arange(H, dtype=np.float32))
    u = gx / W if spine_left else 1 - gx / W
    g = (1 - u) ** 3  # ノドで 1、反対側で 0
    v = gy / H - 0.5
    map_y = gy - amp * H * g * (0.4 + 1.2 * v)
    map_x = gx + (squeeze * W * g if spine_left else -squeeze * W * g)
    return cv2.remap(img, map_x.astype(np.float32), map_y.astype(np.float32),
                     cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)


def overlay(img, lines, color):
    v = img.copy()
    for xs, ys in lines:
        p = np.polyfit(xs, ys, min(3, len(xs) - 1))
        px = np.linspace(xs.min(), xs.max(), 60)
        pts = np.stack([px, np.polyval(p, px)], axis=1).astype(np.int32)
        cv2.polylines(v, [pts], False, color, 2)
    return v


def run_case(name, img, out_dir, rows):
    out, lines, field = dewarp(img)
    gray_out = cv2.cvtColor(out, cv2.COLOR_BGR2GRAY)
    lines_after = detect_lines(gray_out)
    b0, b1 = bend(lines), bend(lines_after)
    rows.append((name, len(lines), b0, b1, field))
    a = overlay(img, lines, (0, 0, 255))
    c = overlay(out, lines_after, (0, 160, 0))
    s = 700 / a.shape[0]
    sheet = np.hstack([cv2.resize(a, None, fx=s, fy=s), cv2.resize(c, None, fx=s, fy=s)])
    cv2.imwrite(os.path.join(out_dir, name + ".jpg"), sheet, [cv2.IMWRITE_JPEG_QUALITY, 85])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=os.path.join(ROOT, "training_data", "eval_hard"))
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "dewarp"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    rows = []
    for jp in sorted(glob.glob(os.path.join(args.data, "*.json"))):
        meta = json.load(open(jp, encoding="utf-8"))
        if not meta.get("corners"):
            continue
        img = cv2.imread(os.path.join(args.data, meta["image"]))
        flat = rectify(img, meta["corners"])
        stem = os.path.splitext(meta["image"])[0]
        run_case(stem, flat, args.out, rows)
        run_case(stem + "_curlL", synth_curl(flat, spine_left=True), args.out, rows)
        run_case(stem + "_curlR", synth_curl(flat, amp=0.05, spine_left=False), args.out, rows)
    print(f"{'case':<22}{'lines':>6}{'bend_before':>13}{'bend_after':>12}  fitted")
    for name, n, b0, b1, ok in rows:
        print(f"{name:<22}{n:>6}{b0:>13.1f}{b1:>12.1f}  {'yes' if ok else 'no'}")


if __name__ == "__main__":
    main()
