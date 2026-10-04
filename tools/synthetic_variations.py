# -*- coding: utf-8 -*-
"""紙面合成の追加素材。評価画像や未検証の四隅ラベルは参照しない。"""

import cv2
import numpy as np


BACKGROUND_KINDS = ("wood", "fabric", "checker", "tiles", "stone", "plain", "desk")
PAPER_KINDS = ("text", "music", "magazine", "form", "receipt", "dark_flyer", "notebook")
PROFILE_DEFAULTS = {
    "legacy": dict(p_multi=0.0, p_occluder=0.0, p_panel=0.0,
                   p_procedural=0.0, p_negative=0.05, p_clipped=0.0, p_stack=0.0),
    "diverse": dict(p_multi=0.20, p_occluder=0.15, p_panel=0.35,
                    p_procedural=0.30, p_negative=0.12, p_clipped=0.0, p_stack=0.0),
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
