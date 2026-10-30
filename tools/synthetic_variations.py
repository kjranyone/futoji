# -*- coding: utf-8 -*-
"""紙面合成の追加素材。評価画像や未検証の四隅ラベルは参照しない。"""

import cv2
import numpy as np


BACKGROUND_KINDS = ("wood", "fabric", "checker", "tiles", "stone", "plain", "desk")
PAPER_KINDS = ("text", "music", "magazine", "form", "receipt", "dark_flyer", "notebook")
FOLD_KINDS = ("dogear", "curl")
CORNER_OBJECT_KINDS = ("phone", "cup", "hand")
PROFILE_DEFAULTS = {
    "legacy": dict(p_multi=0.0, p_occluder=0.0, p_panel=0.0,
                   p_procedural=0.0, p_negative=0.05, p_clipped=0.0, p_stack=0.0,
                   p_fold=0.0, p_corner_object=0.0, p_same=0.0),
    "diverse": dict(p_multi=0.20, p_occluder=0.15, p_panel=0.35,
                    p_procedural=0.30, p_negative=0.12, p_clipped=0.0, p_stack=0.0,
                    p_fold=0.0, p_corner_object=0.0, p_same=0.0),
}


def procedural_background(rng, width, height, kind=None):
    """布・タイル・石・白い机・電子機器など、紙を含まない背景。"""
    kind = kind or str(rng.choice(BACKGROUND_KINDS))
    if kind not in BACKGROUND_KINDS:
        raise ValueError(f"unknown background: {kind}")
    yy, xx = np.mgrid[:height, :width].astype(np.float32)
    angle = rng.uniform(0, np.pi)
    u = xx * np.cos(angle) + yy * np.sin(angle)
    v = -xx * np.sin(angle) + yy * np.cos(angle)
    base = rng.uniform(0.08, 0.85, 3)
    if kind == "plain":
        base = np.full(3, rng.uniform(0.72, 0.98))
    img = np.broadcast_to(base, (height, width, 3)).copy().astype(np.float32)
    if kind == "wood":
        grain = np.sin(u / rng.uniform(3, 14) + 0.7 * np.sin(v / 45))
        img += grain[..., None] * rng.uniform(0.02, 0.10)
    elif kind == "fabric":
        weave = np.sin(u * 1.8) * np.sin(v * 2.0)
        pattern = np.sin(u / rng.uniform(4, 15)) * np.cos(v / rng.uniform(4, 15))
        img += (0.025 * weave + rng.uniform(0.05, 0.20) * pattern)[..., None]
    elif kind in ("checker", "tiles"):
        cell = rng.uniform(12, 55)
        if kind == "checker":
            pattern = (np.floor(u / cell) + np.floor(v / cell)) % 2
            other = rng.uniform(0.05, 0.95, 3)
            img = img * (1 - pattern[..., None]) + other * pattern[..., None]
        else:
            grout = ((u % cell < 2) | (v % cell < 2)).astype(np.float32)
            img *= 1 - grout[..., None] * rng.uniform(0.25, 0.70)
    elif kind == "stone":
        coarse = rng.normal(0, 0.06, (height, width)).astype(np.float32)
        coarse = cv2.GaussianBlur(coarse, (0, 0), 2)
        img += coarse[..., None]
        for _ in range(350):
            center = (int(rng.integers(width)), int(rng.integers(height)))
            cv2.circle(img, center, int(rng.integers(1, 4)),
                       rng.uniform(0.05, 0.9, 3).tolist(), -1)
    if kind == "desk":
        # ガラス画面の中の印刷物風レイアウトも負例。物理的な紙ではない。
        x0, y0 = int(width * 0.12), int(height * 0.14)
        x1, y1 = int(width * 0.70), int(height * 0.76)
        cv2.rectangle(img, (x0, y0), (x1, y1), (0.04, 0.04, 0.04), -1)
        cv2.rectangle(img, (x0 + 7, y0 + 7), (x1 - 7, y1 - 7), (0.75, 0.75, 0.75), -1)
        cv2.rectangle(img, (x0 + 12, y0 + 15), (x1 - 12, y0 + int((y1 - y0) * 0.4)),
                      rng.uniform(0.1, 0.65, 3).tolist(), -1)
        for y in range(y0 + int((y1 - y0) * 0.5), y1 - 12, 8):
            cv2.line(img, (x0 + 14, y), (x1 - 16, y), (0.18, 0.18, 0.18), 1)
    # マグ・ケーブル・白いプラスチック物体などの紛らわしい輪郭。
    for _ in range(int(rng.integers(1, 5))):
        x, y = int(rng.integers(width)), int(rng.integers(height))
        color = rng.uniform(0.05, 0.98, 3).tolist()
        if rng.random() < 0.5:
            radius = int(rng.integers(8, max(9, min(width, height) // 7)))
            cv2.circle(img, (x, y), radius, color, -1)
            cv2.circle(img, (x, y), max(2, radius - 4), (0.13, 0.13, 0.13), 2)
        else:
            pts = rng.uniform([0, 0], [width, height], (5, 2)).astype(np.int32)
            cv2.polylines(img, [pts], False, color, int(rng.integers(2, 5)))
    img += rng.normal(0, 0.008, (height, width, 1)).astype(np.float32)
    return np.clip(img, 0, 1).astype(np.float32)


def procedural_paper(rng, kind=None):
    """外周が既知の平面紙。文字・楽譜の意味の正解は作らない。"""
    kind = kind or str(rng.choice(PAPER_KINDS))
    if kind not in PAPER_KINDS:
        raise ValueError(f"unknown paper: {kind}")
    width = 360
    aspect = rng.uniform(0.65, 1.6)
    if kind == "receipt":
        aspect = rng.uniform(2.2, 3.5)
    height = round(width * aspect)
    base = rng.uniform(0.78, 0.99, 3)
    if kind == "dark_flyer":
        base = rng.uniform(0.04, 0.25, 3)
    img = np.broadcast_to(base, (height, width, 3)).copy().astype(np.float32)
    img += rng.normal(0, 0.005, (height, width, 1)).astype(np.float32)
    margin = int(rng.integers(12, 30))
    ink = (0.10, 0.10, 0.10) if kind != "dark_flyer" else (0.88, 0.88, 0.88)
    if kind in ("magazine", "dark_flyer"):
        for _ in range(int(rng.integers(2, 6))):
            x0, y0 = int(rng.integers(0, width - 60)), int(rng.integers(0, height - 40))
            x1 = min(width - 1, x0 + int(rng.integers(60, width)))
            y1 = min(height - 1, y0 + int(rng.integers(40, max(41, height // 2))))
            # 写真に似た階調も、同じ紙面の印刷領域として含める。
            color = rng.uniform(0.03, 0.95, 3).astype(np.float32)
            patch = rng.uniform(0.45, 1.0, (y1 - y0, x1 - x0, 1)).astype(np.float32)
            patch = cv2.GaussianBlur(patch, (0, 0), 3)
            img[y0:y1, x0:x1] = patch.reshape(y1 - y0, x1 - x0, 1) * color
    if kind == "music":
        for y in range(margin + 15, height - margin - 35, 70):
            for j in range(5):
                cv2.line(img, (margin, y + 6 * j), (width - margin, y + 6 * j), ink, 1)
            for x in range(margin + 20, width - margin, 28):
                ny = y + int(rng.integers(-1, 6)) * 6
                cv2.ellipse(img, (x, ny), (4, 3), -20, 0, 360, ink, -1)
                cv2.line(img, (x + 4, ny), (x + 4, ny - 20), ink, 1)
    elif kind == "form":
        for y in range(margin + 30, height - margin, 30):
            cv2.line(img, (margin, y), (width - margin, y), ink, 1)
        for x in np.linspace(margin, width - margin, 5).astype(int):
            cv2.line(img, (int(x), margin + 30), (int(x), height - margin), ink, 1)
    elif kind == "notebook":
        for y in range(margin + 20, height - margin, 16):
            cv2.line(img, (margin, y), (width - margin, y), (0.65, 0.55, 0.55), 1)
        cv2.line(img, (margin + 20, 0), (margin + 20, height - 1), (0.45, 0.45, 0.80), 1)
    else:
        columns = 2 if kind == "magazine" else 1
        col_width = (width - 2 * margin) // columns
        for c in range(columns):
            x0 = margin + c * col_width
            for y in range(margin + 25, height - margin, int(rng.integers(9, 17))):
                end = x0 + int(rng.uniform(0.35, 0.95) * col_width)
                cv2.line(img, (x0, y), (end, y), ink, int(rng.integers(1, 3)))
    img = (np.clip(img, 0, 1) * 255).astype(np.uint8)
    quad = np.array([[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]], np.float64)
    return "procedural_" + kind, img, quad


def object_occluder(rng, canvas, quad):
    """ペン・ケーブル・指に似た小物。主な紙の全体マスクは保持する。"""
    height, width = canvas.shape[:2]
    edge = int(rng.integers(4))
    t = rng.uniform(0.2, 0.8)
    center = quad[edge] * (1 - t) + quad[(edge + 1) % 4] * t
    scale = min(width, height)
    angle = rng.uniform(0, 2 * np.pi)
    direction = np.array([np.cos(angle), np.sin(angle)])
    length = rng.uniform(0.06, 0.22) * scale
    p0, p1 = (center - length * direction).astype(int), (center + length * direction).astype(int)
    thick = max(2, round(rng.uniform(0.01, 0.045) * scale))
    layer = np.zeros((height, width), np.float32)
    cv2.line(layer, tuple(p0), tuple(p1), 1.0, thick)
    cv2.circle(layer, tuple(p1), max(1, thick // 2), 1.0, -1)
    shadow = cv2.GaussianBlur(layer, (0, 0), 2)
    canvas = canvas * (1 - shadow[..., None] * 0.25)
    color = rng.uniform(0.03, 0.30, 3) if rng.random() < 0.65 else rng.uniform(0.40, 0.78, 3)
    return canvas * (1 - layer[..., None]) + color * layer[..., None]


def _poly_alpha(poly, height, width, ss=4):
    """多角形を 4 倍で塗って縮小した、縁の滑らかな alpha (0..1)。"""
    big = np.zeros((height * ss, width * ss), np.uint8)
    cv2.fillPoly(big, [(np.asarray(poly) * ss).round().astype(np.int32)], 255)
    return cv2.resize(big, (width, height), interpolation=cv2.INTER_AREA).astype(np.float32) / 255.0


def _affine_about_line(p1, normal, scale):
    """直線 (p1 を通り normal に垂直) からの距離を scale 倍する 2x3 アフィン変換。

    scale=-1 で折り返し (鏡像)、0..1 で直線へ寄せる (持ち上がった角の見かけの縮み)。"""
    a = np.eye(2) - (1 - scale) * np.outer(normal, normal)
    t = (1 - scale) * float(p1 @ normal) * normal
    return np.hstack([a, t[:, None]])


def fold_corner(rng, under, warped, alpha, quad, kind=None):
    """主な紙の角を 1 つ折り返す (dogear) か、めくれて持ち上げる (curl)。

    under は紙を貼る前の背景、warped は紙の絵 (どちらも float BGR 0..1)、alpha は紙全体の
    四角形。合成した canvas を返す。正解マスクは呼び出し側で紙全体の四角形のまま使う
    (四隅を求めたいので、辺を延ばした交点が角)。
    - dogear: 角の三角形を折り目で紙の上へ折り返す。裏面 (無地 + 薄い透け) が見え、
      元の角のところは背景が見える
    - curl: 角が丸く欠け、持ち上がった部分は折り目へ寄せて縮んで見える。欠けた所の背景に
      影が落ちる
    """
    kind = kind or str(rng.choice(FOLD_KINDS))
    if kind not in FOLD_KINDS:
        raise ValueError(f"unknown fold: {kind}")
    height, width = alpha.shape
    i = int(rng.integers(4))
    c, prev, nxt = quad[i], quad[(i - 1) % 4], quad[(i + 1) % 4]
    a = rng.uniform(0.10, 0.35)
    b = float(np.clip(a * rng.uniform(0.6, 1.6), 0.08, 0.45))
    p1, p2 = c + (prev - c) * a, c + (nxt - c) * b
    d = (p2 - p1) / max(np.linalg.norm(p2 - p1), 1e-6)
    normal = np.array([-d[1], d[0]])
    if (c - p1) @ normal < 0:
        normal = -normal  # 角の側を向く
    if kind == "curl":
        # 見えている紙の縁は角の側へふくらむ曲線 (丸く欠けた角)
        ctrl = (p1 + p2) / 2 + (c - (p1 + p2) / 2) * rng.uniform(0.15, 0.6)
        t = np.linspace(0, 1, 24)[:, None]
        curve = (1 - t) ** 2 * p1 + 2 * (1 - t) * t * ctrl + t ** 2 * p2
        cut = np.vstack([curve, c[None]])
    else:
        cut = np.array([p1, p2, c])
    cut_a = np.minimum(_poly_alpha(cut, height, width), alpha)
    visible = alpha - cut_a
    canvas = under.copy()
    if kind == "curl":
        # 持ち上がった角が背景へ落とす影
        sh = cv2.GaussianBlur(cut_a, (0, 0), rng.uniform(2, 8))
        canvas *= 1 - sh[..., None] * rng.uniform(0.2, 0.55)
    canvas = canvas * (1 - visible[..., None]) + warped * visible[..., None]
    bright = warped[alpha > 0.5]
    base = (np.percentile(bright, 80, axis=0) if len(bright) else np.full(3, 0.9)).astype(np.float32)
    tri = np.array([p1, c, p2])
    if kind == "dogear":
        m = _affine_about_line(p1, normal, -1.0)
    else:
        m = _affine_about_line(p1, normal, rng.uniform(0.25, 0.85))
        m[:, 2] += normal * rng.uniform(0, 0.08) * np.linalg.norm(p2 - p1)
    flap_poly = cv2.transform(tri[None].astype(np.float32), m)[0]
    flap = _poly_alpha(flap_poly, height, width)
    show = cv2.warpAffine(warped, m.astype(np.float32), (width, height), flags=cv2.INTER_LINEAR,
                          borderMode=cv2.BORDER_REFLECT)
    if kind == "dogear" or rng.random() < 0.5:
        # 裏面: 無地に表の印刷が薄く透ける (折り返すと鏡像)
        k = rng.uniform(0.0, 0.2)
        show = base * (1 - k) + show * k
    # 折り目からの距離で陰影 (曲がった面の明るさの変化)
    yy, xx = np.mgrid[:height, :width].astype(np.float32)
    dist = (xx - p1[0]) * normal[0] + (yy - p1[1]) * normal[1]
    span = max(float(np.abs((tri - p1) @ normal).max()), 1.0)
    ramp = np.clip(np.abs(dist) / span, 0, 1)
    g0, g1 = rng.uniform(0.7, 1.0), rng.uniform(0.75, 1.1)
    show = show * (g0 + (g1 - g0) * ramp)[..., None]
    sh = cv2.GaussianBlur(np.roll(flap, (int(rng.integers(-3, 4)), int(rng.integers(-3, 4))),
                                  axis=(0, 1)), (0, 0), rng.uniform(1, 4))
    canvas *= 1 - sh[..., None] * rng.uniform(0.1, 0.35)
    return np.clip(canvas * (1 - flap[..., None]) + show * flap[..., None], 0, 1).astype(np.float32)


def corner_object(rng, canvas, quad, kind=None):
    """紙の角を覆うスマホ・カップ・手。主な紙の全体マスクは保持する。"""
    kind = kind or str(rng.choice(CORNER_OBJECT_KINDS))
    if kind not in CORNER_OBJECT_KINDS:
        raise ValueError(f"unknown corner object: {kind}")
    height, width = canvas.shape[:2]
    c = quad[int(rng.integers(4))]
    center_paper = quad.mean(0)
    side = np.sqrt(abs(cv2.contourArea(quad.astype(np.float32))))
    size = rng.uniform(0.22, 0.50) * side
    inward = (center_paper - c) / max(np.linalg.norm(center_paper - c), 1e-6)
    perp = np.array([-inward[1], inward[0]])
    layer = np.zeros((height, width), np.float32)
    paint = np.zeros((height, width, 3), np.float32)
    yy, xx = np.mgrid[:height, :width].astype(np.float32)

    def put(a, color):
        paint[:] = paint * (1 - a[..., None]) + np.asarray(color, np.float32) * a[..., None]
        np.maximum(layer, a, out=layer)

    if kind == "phone":
        center = c + inward * rng.uniform(-0.15, 0.3) * size + perp * rng.uniform(-0.2, 0.2) * size
        w, h = size, size * rng.uniform(1.8, 2.2)
        ang = rng.uniform(0, 180)
        box = ((float(center[0]), float(center[1])), (w, h), ang)
        r = max(1, int(0.12 * w))
        inner = cv2.boxPoints((box[0], (max(1, w - 2 * r), max(1, h - 2 * r)), ang))
        body = cv2.dilate(_poly_alpha(inner, height, width),
                          cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1)))
        case = rng.uniform(0.02, 0.15, 3) if rng.random() < 0.6 else rng.uniform(0.2, 0.9, 3)
        put(body, case)
        screen = _poly_alpha(cv2.boxPoints((box[0], (w * 0.88, h * 0.9), ang)), height, width)
        t = np.radians(ang)
        glow = rng.uniform(0.02, 0.12) + rng.uniform(0, 0.25) * np.clip(
            ((xx - center[0]) * np.cos(t) + (yy - center[1]) * np.sin(t)) / max(h, 1) + 0.5, 0, 1)
        paint[:] = (paint * (1 - screen[..., None])
                    + glow[..., None] * rng.uniform(0.8, 1.2, 3) * screen[..., None])
    elif kind == "cup":
        center = c + inward * rng.uniform(-0.1, 0.25) * size + perp * rng.uniform(-0.2, 0.2) * size
        rad = size * rng.uniform(0.5, 0.75)
        mug = rng.uniform(0.5, 0.95, 3) if rng.random() < 0.6 else rng.uniform(0.05, 0.6, 3)
        hang = rng.uniform(0, 2 * np.pi)
        hc = center + rad * 1.05 * np.array([np.cos(hang), np.sin(hang)])
        handle = np.zeros((height, width), np.float32)
        cv2.circle(handle, (int(hc[0]), int(hc[1])), max(2, int(rad * 0.38)), 1.0,
                   max(2, int(rad * 0.16)))
        put(handle, mug * 0.9)
        r2 = (xx - center[0]) ** 2 + (yy - center[1]) ** 2
        put((r2 <= rad ** 2).astype(np.float32), mug)
        drink = (rng.uniform([0.05, 0.10, 0.18], [0.15, 0.25, 0.40]) if rng.random() < 0.6
                 else mug * 0.75)
        paint[r2 <= (rad * 0.82) ** 2] = drink
    else:
        # 手: 紙の外から角の上へ伸びる手のひらと指 (手首は画面の外まで続く)
        out_dir = -inward + perp * rng.uniform(-0.6, 0.6)
        out_dir /= np.linalg.norm(out_dir)
        across = np.array([-out_dir[1], out_dir[0]])
        size *= 1.3
        tip = c + inward * rng.uniform(0.15, 0.6) * size
        palm_c = tip + out_dir * size * 0.9
        skin = np.array([0.55, 0.68, 0.88]) * rng.uniform(0.55, 1.05) * rng.uniform(0.93, 1.07, 3)
        hand = np.zeros((height, width), np.float32)
        ang = float(np.degrees(np.arctan2(out_dir[1], out_dir[0])))
        cv2.ellipse(hand, (int(palm_c[0]), int(palm_c[1])), (int(size * 0.65), int(size * 0.5)),
                    ang, 0, 360, 1.0, -1)
        far = palm_c + out_dir * size * 3
        cv2.line(hand, (int(palm_c[0]), int(palm_c[1])), (int(far[0]), int(far[1])), 1.0,
                 max(2, int(size * 0.7)))
        for k in np.linspace(-1, 1, 4):
            root = palm_c - out_dir * size * 0.4 + across * k * size * 0.35
            end = root - out_dir * size * rng.uniform(0.6, 0.9) + across * k * size * 0.1
            cv2.line(hand, (int(root[0]), int(root[1])), (int(end[0]), int(end[1])), 1.0,
                     max(2, int(size * 0.16)))
        put(cv2.GaussianBlur(hand, (0, 0), 1.0), skin)
        shade = 0.85 + 0.25 * np.clip(((xx - palm_c[0]) * across[0] + (yy - palm_c[1]) * across[1])
                                      / max(size, 1) + 0.5, 0, 1)
        paint *= shade[..., None]
    sh = cv2.GaussianBlur(np.roll(layer, (int(rng.integers(-6, 7)), int(rng.integers(-6, 7))),
                                  axis=(0, 1)), (0, 0), rng.uniform(2, 8))
    canvas = canvas * (1 - sh[..., None] * rng.uniform(0.2, 0.45))
    return np.clip(canvas * (1 - layer[..., None]) + paint * layer[..., None], 0, 1).astype(np.float32)


def camera_effects(rng, img):
    """窓の縞影・反射・色かぶり・手ぶれ・低解像度の追加。幾何は変えない。"""
    height, width = img.shape[:2]
    yy, xx = np.mgrid[:height, :width].astype(np.float32)
    if rng.random() < 0.30:
        angle = rng.uniform(0, np.pi)
        u = xx * np.cos(angle) + yy * np.sin(angle)
        stripes = (np.sin(u / rng.uniform(7, 22)) > rng.uniform(-0.3, 0.3)).astype(np.float32)
        stripes = cv2.GaussianBlur(stripes, (0, 0), rng.uniform(0.7, 3))
        img = img * (1 - stripes[..., None] * rng.uniform(0.15, 0.50))
    if rng.random() < 0.20:
        cx, cy = rng.uniform(0, width), rng.uniform(0, height)
        sx, sy = rng.uniform(0.08, 0.30) * width, rng.uniform(0.08, 0.30) * height
        glare = np.exp(-0.5 * (((xx - cx) / sx) ** 2 + ((yy - cy) / sy) ** 2))
        img += glare[..., None] * rng.uniform(0.15, 0.45)
    img = img * rng.uniform(0.85, 1.15, 3)
    if rng.random() < 0.20:
        size = int(rng.choice([3, 5, 7, 9]))
        kernel = np.zeros((size, size), np.float32)
        if rng.random() < 0.5:
            kernel[size // 2, :] = 1 / size
        else:
            kernel[:, size // 2] = 1 / size
        img = cv2.filter2D(img, -1, kernel)
    if rng.random() < 0.20:
        factor = rng.uniform(0.35, 0.7)
        small = cv2.resize(img, (max(1, round(width * factor)), max(1, round(height * factor))),
                           interpolation=cv2.INTER_AREA)
        img = cv2.resize(small, (width, height), interpolation=cv2.INTER_LINEAR)
    return np.clip(img, 0, 1).astype(np.float32)
