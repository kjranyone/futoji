"""ストア掲載画像の撮影用に、生成楽譜写真 (training_data/paper_photos) からサンプル教材を
Futoji のバックアップ zip として作る。

- 四隅ラベル (quads.json, ok=true) で台形補正した画像をページ本文 (WebP) にする
  (アプリの warper と同じく、出力サイズは向かい合う辺の平均長)
- サムネイルは長辺 420px
- 一部のページには手書き (赤丸・青の波線) を入れる

出力: build/store_samples/futoji_backup_promo.zip と pages/<pageId>_<photoId>.png (補正後ページ)
端末へ:  adb push build/store_samples/futoji_backup_promo.zip /sdcard/Download/
         → アプリの 設定 → バックアップから復元 で読み込む (私物の教材はそのまま残る)。
撮り終えたら端末の教材を消す (ホームで長押し → 削除)。
"""
import io
import json
import math
import time
import zipfile
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "training_data" / "paper_photos"
OUT = ROOT / "build" / "store_samples"
PAGES = OUT / "pages"

# 色はアプリのペン (viewer_screen.dart の _colors) と同じ
BLACK, RED, BLUE = 0xFF212121, 0xFFE53935, 0xFF1E88E5


def ellipse(cx, cy, rx, ry, n=48, start=0.0, turns=1.05):
    return [(cx + rx * math.cos(t), cy + ry * math.sin(t))
            for t in (start + 2 * math.pi * turns * i / n for i in range(n + 1))]


def wavy(x0, x1, y, amp=0.004, n=40):
    return [(x0 + (x1 - x0) * i / n, y + amp * math.sin(i * 1.3)) for i in range(n + 1)]


def stroke(color, pts, width=0.007):
    return {"c": color, "w": width, "p": [v for p in pts for v in p]}


# 教材: (id, タイトル, タグ, [写真 id], {ページ番号: [strokes]})。先頭ほど新しい教材になる
DOCS = [
    ("promo_piano", "ピアノ教本 1", ["ピアノ"], ["0003", "0004", "0007", "0073", "0005"],
     {0: [stroke(RED, ellipse(0.62, 0.33, 0.16, 0.05)),
          stroke(BLUE, wavy(0.12, 0.55, 0.62))]}),
    ("promo_choir", "春のコンサート (合唱)", ["合唱", "発表会"], ["0013", "0014", "0018", "0020"], {}),
    ("promo_jazz", "Autumn Leaves", ["ジャズ"], ["0043", "0045", "0046"],
     {0: [stroke(RED, ellipse(0.50, 0.42, 0.20, 0.06)),
          stroke(RED, wavy(0.15, 0.80, 0.70, amp=0.003)),
          stroke(BLUE, ellipse(0.80, 0.22, 0.08, 0.04))]}),
    ("promo_violin", "ヴァイオリン エチュード", ["ヴァイオリン"], ["0023", "0024", "0027"], {}),
    ("promo_theory", "音楽理論ワークシート", ["理論"], ["0029", "0032", "0049", "0051"], {}),
    ("promo_notes", "レッスンノート", ["メモ"], ["0063", "0064", "0012", "0059"], {}),
    ("promo_rhythm", "リズム練習 (打楽器)", ["打楽器"], ["0083", "0084", "0087"], {}),
    ("promo_class", "音楽クラス プリント", ["クラス"], ["0089", "0091", "0092"], {}),
    ("promo_flute", "フルート ソロ", ["フルート"], ["0093", "0095", "0096"], {}),
    ("promo_guitar", "ギター TAB 譜", ["ギター"], ["0033", "0034", "0035", "0037"], {}),
    ("promo_orch", "オーケストラ 抜粋", ["オーケストラ"], ["0053", "0054", "0056"], {}),
    ("promo_check", "練習チェックリスト", ["練習"], ["0039", "0040", "0042"], {}),
]


def warp(quads: dict, img_id: str):
    """四隅ラベルで台形補正し (RGB ndarray, w, h) を返す。"""
    im = Image.open(SRC / "images" / f"{img_id}.png").convert("RGB")
    a = np.asarray(im)
    H, W = a.shape[:2]
    src = np.float32([[x * W, y * H] for x, y in quads[img_id]["quad"]])

    def d(p, r):
        return float(np.hypot(*(src[p] - src[r])))
    w = int(round((d(0, 1) + d(3, 2)) / 2))
    h = int(round((d(0, 3) + d(1, 2)) / 2))
    dst = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    out = cv2.warpPerspective(a, cv2.getPerspectiveTransform(src, dst), (w, h),
                              flags=cv2.INTER_CUBIC)
    return out, w, h


def to_webp(arr, quality):
    buf = io.BytesIO()
    Image.fromarray(arr).save(buf, "WEBP", quality=quality, method=4)
    return buf.getvalue()


def thumb(arr, long_edge=420):
    im = Image.fromarray(arr)
    im.thumbnail((long_edge, long_edge), Image.LANCZOS)
    return np.asarray(im)


def main() -> None:
    PAGES.mkdir(parents=True, exist_ok=True)
    quads = json.load(open(SRC / "quads.json", encoding="utf-8"))
    now = int(time.time() * 1000)
    docs_json, pages_json, files = [], [], {}
    for di, (doc_id, title, tags, images, strokes) in enumerate(DOCS):
        updated = now - di * 7 * 60 * 1000          # 約 7 分おきに古くなる
        created = updated - (3 + di) * 24 * 3600 * 1000
        docs_json.append({"id": doc_id, "title": title, "createdAt": created,
                          "updatedAt": updated, "tags": tags})
        for pi, img_id in enumerate(images):
            arr, w, h = warp(quads, img_id)
            page_id = f"{doc_id}_p{pi + 1}"
            files[f"images/{page_id}.webp"] = to_webp(arr, 90)
            files[f"thumbs/{page_id}.webp"] = to_webp(thumb(arr), 80)
            Image.fromarray(arr).save(PAGES / f"{page_id}_{img_id}.png")
            pages_json.append({"id": page_id, "documentId": doc_id, "index": pi,
                               "width": w, "height": h, "updatedAt": updated, "note": "",
                               "strokes": strokes.get(pi, [])})
            print(f"{doc_id} p{pi + 1} <- {img_id}  {w}x{h}")

    manifest = {"format": "futoji-backup", "version": 1, "createdAt": now,
                "documents": len(docs_json), "pages": len(pages_json)}
    zip_path = OUT / "futoji_backup_promo.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_STORED) as z:
        z.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False))
        z.writestr("data.json", json.dumps({"documents": docs_json, "pages": pages_json},
                                           ensure_ascii=False))
        for name, data in files.items():
            z.writestr(name, data)
    print("zip:", zip_path, zip_path.stat().st_size // 1024, "KB")


if __name__ == "__main__":
    main()
