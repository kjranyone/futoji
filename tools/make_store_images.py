"""ストア掲載用の紹介画像を作る。

素材:
  - 実機のスクリーンショット (--shots)。端末は HiPad (1600x2560, 320dpi)。
    スマホ向けは `adb shell wm size 1080x2340; wm density 440` で撮った 1080x2340。
    ファイル名は下の SHOTS を参照 (p_ 始まりがスマホ)。
  - training_data/paper_photos/images (生成した楽譜写真。ライセンスの心配がない) と
    その四隅ラベル quads.json。カメラ・切り抜き画面はプレビュー部分をこの写真に
    差し替え、アプリと同じ描き方で検出枠を描く (実機ではカメラの前に紙を置けないため)。
  - 補正後ページは quads.json で台形補正した画像 (--pages。promo の make_backup.py 出力)。

出力 (--out, 既定 docs/store):
  phone/   1080x1920   Google Play スマホ用 (9:16)        JPEG 品質 95
  tablet/  1620x2880   Google Play 10 インチタブレット用 (9:16)
  iphone/  1290x2796   App Store 6.7 インチ   (大きいので git 管理外。必要なら再生成)
  ipad/    2048x2732   App Store 12.9 インチ  (同上)
  feature_graphic.png  1024x500 Google Play の宣伝用画像
  --readme (既定 docs/images) に README 掲載用 WebP (幅 540)
  build/store_screens/ 合成したカメラ・切り抜き画面そのもの (確認用 PNG)

使い方:
  python tools/make_store_samples.py          # 生成写真からサンプル教材のバックアップ zip を作る
  (zip を端末の Download に置き、設定 → バックアップから復元。各画面を adb screencap で撮る)
  python tools/make_store_images.py --shots <スクショの入ったフォルダ> --pages <補正後ページ>

手順の詳細は docs/RELEASE.md の「ストア掲載画像」。
"""
from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
PHOTOS = ROOT / "training_data" / "paper_photos"
FONT_JP = Path(r"C:\Windows\Fonts\NotoSansJP-VF.ttf")
FONT_ICON = Path(r"C:\lib\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf")
ICON = {"auto_awesome": "\ue0b7", "check": "\ue156"}

INDIGO = (0x3B, 0x4A, 0x9F)
INDIGO_DARK = (0x25, 0x2E, 0x6E)
GREEN = (0x4C, 0xAF, 0x50)
WHITE = (255, 255, 255)


# ------------------------------------------------------------------ 端末ごとの寸法

@dataclass(frozen=True)
class Device:
    name: str
    size: tuple[int, int]
    dpr: float            # 1dp あたりの px
    status_bar: int       # 上から切り落とす高さ (px)
    nav_top: int          # ここから下を切り落とす (px)
    preview: tuple[int, int]        # カメラ画面のプレビュー領域 (y0, y1)。幅は全幅
    crop_rect: tuple[int, int, int, int]  # 切り抜き画面の画像矩形 (x0, y0, x1, y1)
    crop_msg: tuple[int, int]       # 切り抜き画面の下部メッセージ行 (y0, y1)
    shutter: tuple[int, int, int, int, int]  # (cx, cy, 外径半径, 輪の太さ, 内側の円の半径)
    home_mask: tuple[int, int] | None = None  # ホーム画面で消す行 (開発端末の私物の教材)

    def dp(self, v: float) -> int:
        return round(v * self.dpr)


PHONE = Device("phone", (1080, 2340), 2.75, 66, 2208, (389, 1823), (33, 509, 1047, 1861),
               (2110, 2208), (540, 2018, 104, 10, 79))
TABLET = Device("tablet", (1600, 2560), 2.0, 48, 2448, (165, 2448), (24, 248, 1576, 2318),
                (2375, 2448), (800, 2319, 75, 7, 57), home_mask=(1790, 2310))

# スクリーンショットのファイル名 (端末 → 画面 → ファイル)
SHOTS = {
    "phone": {"home": "p_home.png", "doc": "p_doc.png", "doc_menu": "p_doc_menu.png",
              "viewer": "p_viewer_bar.png", "draw": "p_viewer_draw.png",
              "camera": "p_camera_auto.png", "crop": "p_crop.png", "settings": "p_settings.png"},
    "tablet": {"home": "home_promo2.png", "doc": "doc_piano.png", "viewer": "viewer_bar.png",
               "draw": "viewer_draw.png", "camera": "camera_auto.png", "crop": "crop.png"},
}


# ------------------------------------------------------------------ 描画の道具

_fonts: dict[tuple[str, int, int], ImageFont.FreeTypeFont] = {}


def font(size: int, weight: int = 400) -> ImageFont.FreeTypeFont:
    key = ("jp", size, weight)
    if key not in _fonts:
        f = ImageFont.truetype(str(FONT_JP), size)
        f.set_variation_by_axes([weight])
        _fonts[key] = f
    return _fonts[key]


def icon_font(size: int) -> ImageFont.FreeTypeFont:
    key = ("icon", size, 0)
    if key not in _fonts:
        _fonts[key] = ImageFont.truetype(str(FONT_ICON), size)
    return _fonts[key]


def gradient(size: tuple[int, int], top=(0x46, 0x56, 0xB6), bottom=INDIGO_DARK) -> Image.Image:
    w, h = size
    t = np.linspace(0, 1, h)[:, None, None]
    a = (np.array(top)[None, None, :] * (1 - t) + np.array(bottom)[None, None, :] * t)
    img = Image.fromarray(np.repeat(a, w, axis=1).astype(np.uint8), "RGB").convert("RGBA")
    # 右上にやわらかい光
    glow = Image.new("RGBA", size, (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    r = int(w * 0.75)
    g.ellipse([w - r * 0.9, -r * 0.7, w + r * 0.9, r * 0.7], fill=(255, 255, 255, 46))
    glow = glow.filter(ImageFilter.GaussianBlur(w * 0.12))
    return Image.alpha_composite(img, glow)


def shadow(canvas: Image.Image, box: tuple[int, int, int, int], radius: int,
           blur: float, offset=(0, 18), alpha=110) -> None:
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = box
    d.rounded_rectangle([x0 + offset[0], y0 + offset[1], x1 + offset[0], y1 + offset[1]],
                        radius, fill=(0, 0, 0, alpha))
    canvas.alpha_composite(layer.filter(ImageFilter.GaussianBlur(blur)))


def rounded(img: Image.Image, radius: int) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius, fill=255)
    out = img.convert("RGBA")
    out.putalpha(mask)
    return out


def text_block(draw: ImageDraw.ImageDraw, cx: int, y: int, lines: list[str], f, fill,
               spacing: float = 1.25, align_center=True) -> int:
    """複数行を中央揃えで描き、次の y を返す。"""
    for line in lines:
        box = draw.textbbox((0, 0), line, font=f, anchor="la")
        w = box[2] - box[0]
        x = cx - w // 2 if align_center else cx
        draw.text((x, y), line, font=f, fill=fill, anchor="la")
        y += int(f.size * spacing)
    return y


def device_frame(canvas: Image.Image, screen: Image.Image, x: int, y: int, width: int,
                 radius: int, bezel: int, *, bleed: bool = True) -> None:
    """端末風の枠に画面を入れて置く。下は画面の外に流れてよい (bleed)。"""
    scale = width / screen.width
    sh = int(screen.height * scale)
    scr = screen.convert("RGBA").resize((width, sh), Image.LANCZOS)
    box = (x - bezel, y - bezel, x + width + bezel, y + sh + bezel)
    shadow(canvas, box, radius, blur=max(18, width * 0.04), offset=(0, int(width * 0.03)))
    frame = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(frame)
    d.rounded_rectangle(box, radius, fill=(0x12, 0x13, 0x1E, 255),
                        outline=(255, 255, 255, 60), width=2)
    canvas.alpha_composite(frame)
    canvas.alpha_composite(rounded(scr, max(8, radius - bezel)), (x, y))


# ------------------------------------------------------------------ 素材の加工

def squash_black(img: Image.Image, start: int, min_run: int, keep: int) -> Image.Image:
    """start 行より下の真っ黒な帯 (min_run 行以上) を keep 行だけ残して詰める。
    ビューアはページを縦に中央寄せするので、縦長のスマホでは上下に黒が余る。"""
    a = np.asarray(img)
    black = a.max(axis=(1, 2)) < 8
    rows = []
    y = 0
    while y < len(black):
        if y >= start and black[y]:
            e = y
            while e < len(black) and black[e]:
                e += 1
            if e - y >= min_run:
                rows.extend(range(y, y + keep))
            else:
                rows.extend(range(y, e))
            y = e
        else:
            rows.append(y)
            y += 1
    return Image.fromarray(a[rows])


def clean(shot: Image.Image, dev: Device, kind: str) -> Image.Image:
    """ステータスバーとナビゲーションバーを落とす。ホームは開発端末の私物教材を消す。"""
    img = shot.convert("RGB")
    if kind == "home" and dev.home_mask:
        y0, y1 = dev.home_mask
        ImageDraw.Draw(img).rectangle([0, y0, img.width, y1], fill=(0, 0, 0))
    img = img.crop((0, dev.status_bar, img.width, dev.nav_top))
    if kind in ("viewer", "draw"):
        img = squash_black(img, dev.dp(56), dev.dp(24), dev.dp(12))
    return img


def load_photo(photo_id: str) -> tuple[Image.Image, list[tuple[float, float]]]:
    quads = json.load(open(PHOTOS / "quads.json", encoding="utf-8"))
    q = [(float(x), float(y)) for x, y in quads[photo_id]["quad"]]
    return Image.open(PHOTOS / "images" / f"{photo_id}.png").convert("RGB"), q


def cover(photo: Image.Image, box: tuple[int, int, int, int]):
    """矩形を覆うように拡大・中央トリミングし、(画像, 正規化座標→px の関数) を返す。"""
    x0, y0, x1, y1 = box
    bw, bh = x1 - x0, y1 - y0
    s = max(bw / photo.width, bh / photo.height)
    w, h = round(photo.width * s), round(photo.height * s)
    big = photo.resize((w, h), Image.LANCZOS)
    ox, oy = (w - bw) // 2, (h - bh) // 2
    out = big.crop((ox, oy, ox + bw, oy + bh))

    def to_px(p):
        return (x0 + p[0] * w - ox, y0 + p[1] * h - oy)
    return out, to_px


def camera_composite(shot: Image.Image, dev: Device, photo_id: str) -> Image.Image:
    """カメラ画面: プレビューを楽譜写真に差し替え、自動撮影のカウントダウン中の枠を描く。"""
    img = shot.convert("RGBA")
    photo, quad = load_photo(photo_id)
    y0, y1 = dev.preview
    box = (0, y0, img.width, y1)
    view, to_px = cover(photo, box)
    img.paste(view, (0, y0))
    d = ImageDraw.Draw(img)
    pts = [to_px(p) for p in quad]
    # _LiveQuadPainter: 線 3dp + 角の点 (半径 6dp, 黒 38% の縁 2dp)
    d.line(pts + [pts[0]], fill=GREEN, width=dev.dp(3), joint="curve")
    r = dev.dp(6)
    for (x, y) in pts:
        d.ellipse([x - r, y - r, x + r, y + r], fill=GREEN, outline=(0, 0, 0, 97), width=dev.dp(2))
    # _QuadBadge: 枠の中央にカウントダウンの数字 (88sp, w800, 影)
    cx = sum(p[0] for p in pts) / 4
    cy = sum(p[1] for p in pts) / 4
    f = font(dev.dp(88), 800)
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).text((cx, cy), "2", font=f, fill=(0, 0, 0, 220), anchor="mm")
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(dev.dp(6))))
    d.text((cx, cy), "2", font=f, fill=WHITE, anchor="mm")
    # プレビューより下に残っている元のヒント・シャッターを消してから描き直す
    d.rectangle([0, y1, img.width, dev.nav_top], fill=(0, 0, 0, 255))
    # 下のヒント (black45 の丸いピルに white70 の 12sp)。カメラ画面では下端から 116dp
    hint = "紙をかざして止めると、3・2・1 と数えて撮影します"
    hf = font(dev.dp(12), 400)
    tb = d.textbbox((0, 0), hint, font=hf, anchor="la")
    tw, th = tb[2] - tb[0], tb[3] - tb[1]
    px, py = dev.dp(10), dev.dp(3)
    scx = dev.shutter[0]
    top = dev.nav_top - dev.dp(116) - th - py * 2
    pill = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(pill).rounded_rectangle(
        [scx - tw // 2 - px, top, scx + tw // 2 + px, top + th + py * 2], dev.dp(10),
        fill=(0, 0, 0, 115))
    img.alpha_composite(pill)
    d.text((scx, top + py + th // 2), hint, font=hf, fill=(255, 255, 255, 180), anchor="mm")
    # シャッター (PressScale の中身: 白い輪 + 白い円)
    cx, cy, ro, lw, ri = dev.shutter
    d.ellipse([cx - ro, cy - ro, cx + ro, cy + ro], outline=WHITE, width=lw)
    d.ellipse([cx - ri, cy - ri, cx + ri, cy + ri], fill=WHITE)
    return img.convert("RGB")


def crop_composite(shot: Image.Image, dev: Device, photo_id: str) -> Image.Image:
    """切り抜き画面: 画像を楽譜写真に差し替え、検出した四隅の枠とハンドルを描く。"""
    img = shot.convert("RGBA")
    photo, quad = load_photo(photo_id)
    x0, y0, x1, y1 = dev.crop_rect
    view, to_px = cover(photo, dev.crop_rect)
    img.paste(rounded(view, dev.dp(4)), (x0, y0))
    pts = [to_px(p) for p in quad]
    # CornerOverlayPainter: 外側を 0x66000000 で暗くし、白 2.5dp の線
    dark = Image.new("RGBA", img.size, (0, 0, 0, 0))
    dd = ImageDraw.Draw(dark)
    dd.rectangle([x0, y0, x1, y1], fill=(0, 0, 0, 0x66))
    dd.polygon(pts, fill=(0, 0, 0, 0))
    img.alpha_composite(dark)
    d = ImageDraw.Draw(img)
    d.line(pts + [pts[0]], fill=WHITE, width=max(2, round(dev.dpr * 2.5)), joint="curve")
    # ハンドル: 26dp の白い円 (alpha 0.9)、縁 3dp の #3B4A9F、黒 38% のぼかし影
    r = dev.dp(13)
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    for (x, y) in pts:
        ImageDraw.Draw(sh).ellipse([x - r, y - r + 2, x + r, y + r + 2], fill=(0, 0, 0, 97))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(dev.dp(2))))
    for (x, y) in pts:
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, 230),
                  outline=INDIGO, width=dev.dp(3))
    # 下のメッセージを「紙面を自動検出しました」に差し替える
    my0, my1 = dev.crop_msg
    d.rectangle([0, my0, img.width, my1], fill=(0, 0, 0, 255))
    cy = (my0 + my1) // 2
    d.text((dev.dp(16), cy), ICON["auto_awesome"], font=icon_font(dev.dp(16)),
           fill=(255, 255, 255, 138), anchor="lm")
    d.text((dev.dp(16 + 16 + 6), cy), "紙面を自動検出しました", font=font(dev.dp(12)),
           fill=(255, 255, 255, 138), anchor="lm")
    return img.convert("RGB")


# ------------------------------------------------------------------ 紹介画像

@dataclass
class Slide:
    key: str
    title: list[str]
    sub: str
    screen: str | None = None   # SHOTS のキー (None は端末枠なし)
    special: str | None = None  # "before_after"
    fit: bool = False           # True: 画面全体 (下のツールバーまで) を収める


SLIDES = [
    Slide("01_camera", ["かざすだけで、", "楽譜を取り込み"], "紙面を自動で見つけて、止まれば自動で撮影", "camera"),
    Slide("02_crop", ["四隅はあとから、", "指でぴったり"], "自動検出した範囲を指で微調整。回転もワンタップ", "crop"),
    Slide("03_warp", ["斜めから撮っても、", "まっすぐに"], "台形補正に加えて、五線を手がかりに紙の反りも直す",
          special="before_after"),
    Slide("04_home", ["教材ごとに、", "1 冊にまとめる"], "タグと検索で、必要なプリントがすぐ開く", "home"),
    Slide("05_draw", ["楽譜の上に、", "そのまま書き込む"], "3 色のペンと消しゴム。拡大しても位置はずれない", "draw",
          fit=True),
    Slide("06_pdf", ["PDF にして、", "そのまま共有"], "全ページを 1 冊の PDF に。手書きメモも一緒に出力", "doc_menu"),
    Slide("07_backup", ["クラウド不要。", "すべて端末の中に"], "通信しないから安心。バックアップは zip で書き出し",
          "settings"),
]


@dataclass(frozen=True)
class Target:
    folder: str
    size: tuple[int, int]
    device: Device
    frame_radius: int
    bezel: int


TARGETS = [
    Target("phone", (1080, 1920), PHONE, 96, 16),
    Target("iphone", (1290, 2796), PHONE, 120, 18),
    Target("tablet", (1620, 2880), TABLET, 64, 22),
    Target("ipad", (2048, 2732), TABLET, 64, 24),
]


def before_after(canvas: Image.Image, top: int, pages: Path, photo_id: str) -> None:
    """斜めに撮った写真 → 補正後のページ。"""
    W, H = canvas.size
    raw = Image.open(PHOTOS / "images" / f"{photo_id}.png").convert("RGBA")
    page = next(pages.glob(f"*_{photo_id}.png"))
    fixed = Image.open(page).convert("RGBA")
    area_h = H - top - int(H * 0.04)
    # 写真 (左上、少し傾ける)
    rw = int(W * 0.56)
    raw = raw.resize((rw, int(raw.height * rw / raw.width)), Image.LANCZOS)
    raw = rounded(raw, int(W * 0.02)).rotate(5, expand=True, resample=Image.BICUBIC)
    rx, ry = int(W * 0.05), top
    shadow(canvas, (rx + 10, ry + 10, rx + raw.width - 10, ry + raw.height - 10), int(W * 0.02),
           blur=W * 0.03, offset=(0, int(W * 0.02)))
    canvas.alpha_composite(raw, (rx, ry))
    # 補正後 (右下、正立)
    fh = int(area_h * 0.62)
    fixed = fixed.resize((int(fixed.width * fh / fixed.height), fh), Image.LANCZOS)
    fx, fy = W - fixed.width - int(W * 0.06), top + area_h - fixed.height
    shadow(canvas, (fx, fy, fx + fixed.width, fy + fixed.height), int(W * 0.012),
           blur=W * 0.035, offset=(0, int(W * 0.025)), alpha=150)
    canvas.alpha_composite(rounded(fixed, int(W * 0.012)), (fx, fy))
    d = ImageDraw.Draw(canvas)
    # 補正済みの印 (ページの左上の角にかかるように置く。横長の画面では H を基準にする)
    base = min(W, int(H * 0.5625))
    f = font(int(base * 0.03), 700)
    label = "✓ 自動補正"
    tb = d.textbbox((0, 0), label, font=f, anchor="la")
    tw, th = tb[2] - tb[0], tb[3] - tb[1]
    px, py = int(base * 0.022), int(base * 0.012)
    cw, ch = tw + px * 2, th + py * 2
    lx, ly = fx - int(cw * 0.4), fy - int(ch * 0.55)
    d.rounded_rectangle([lx, ly, lx + cw, ly + ch], ch // 2, fill=GREEN)
    d.text((lx + px, ly + py + th // 2), label, font=f, fill=WHITE, anchor="lm")
    # 写真から補正後へ向かうシェブロン (写真の右、補正後ページの上)
    ax, ay = int(W * 0.80), int(fy - W * 0.07)
    s = int(W * 0.045)
    d.line([(ax - s, ay - s), (ax, ay), (ax + s, ay - s)], fill=(255, 255, 255, 230),
           width=int(W * 0.012), joint="curve")


def render_slide(slide: Slide, target: Target, screens: dict[str, Image.Image],
                 pages: Path) -> Image.Image:
    W, H = target.size
    canvas = gradient((W, H))
    d = ImageDraw.Draw(canvas)
    scale = W / 1080
    title_f = font(int(66 * scale), 700)
    sub_f = font(int(34 * scale), 400)
    y = int(92 * scale)
    y = text_block(d, W // 2, y, slide.title, title_f, WHITE, spacing=1.22)
    y += int(14 * scale)
    y = text_block(d, W // 2, y, [slide.sub], sub_f, (255, 255, 255, 222), spacing=1.2)
    top = y + int(44 * scale)
    if slide.special == "before_after":
        before_after(canvas, top, pages, "0043")
    else:
        screen = screens[slide.screen]
        width = int(W * 0.78) if target.device is PHONE else int(W * 0.86)
        bezel = int(target.bezel * scale)
        if slide.fit:
            # 下端まで収める (ツールバーが主役の画面)
            avail = H - top - int(70 * scale) - bezel
            width = min(width, int(avail * screen.width / screen.height))
        x = (W - width) // 2
        device_frame(canvas, screen, x, top, width, int(target.frame_radius * scale), bezel)
    return canvas.convert("RGB")


def feature_graphic(screens: dict[str, Image.Image]) -> Image.Image:
    W, H = 1024, 500
    canvas = gradient((W, H), top=(0x46, 0x56, 0xB6), bottom=(0x2C, 0x37, 0x82))
    d = ImageDraw.Draw(canvas)
    icon = Image.open(ROOT / "assets" / "branding" / "google-play-512.png").convert("RGBA")
    icon = rounded(icon.resize((150, 150), Image.LANCZOS), 34)
    shadow(canvas, (70, 90, 220, 240), 34, blur=18, offset=(0, 10))
    canvas.alpha_composite(icon, (70, 90))
    d.text((250, 104), "Futoji", font=font(70, 700), fill=WHITE, anchor="la")
    d.text((252, 194), "楽譜・プリントを、", font=font(26, 500), fill=(255, 255, 255, 230),
           anchor="la")
    d.text((252, 228), "1 冊のデジタル教材に", font=font(26, 500), fill=(255, 255, 255, 230),
           anchor="la")
    for i, line in enumerate(["自動撮影 ・ 台形補正 ・ 手書きメモ ・ PDF 書き出し",
                              "通信なし。すべて端末の中に保存"]):
        d.text((70, 318 + i * 40), line, font=font(24, 400), fill=(255, 255, 255, 200), anchor="la")
    # 右に少し傾けた端末 (ホーム画面)
    scr = screens["home"]
    w = 300
    scr = scr.convert("RGBA").resize((w, int(scr.height * w / scr.width)), Image.LANCZOS)
    frame = Image.new("RGBA", (w + 32, scr.height + 32), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle([0, 0, w + 31, scr.height + 31], 54,
                                            fill=(0x12, 0x13, 0x1E, 255),
                                            outline=(255, 255, 255, 60), width=2)
    frame.alpha_composite(rounded(scr, 40), (16, 16))
    frame = frame.rotate(-8, expand=True, resample=Image.BICUBIC)
    sh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    a = frame.split()[3].point(lambda v: int(v * 0.55))
    sh.paste((0, 0, 0, 255), (724, 64), mask=a)
    canvas.alpha_composite(sh.filter(ImageFilter.GaussianBlur(14)))
    canvas.alpha_composite(frame, (710, 50))
    return canvas.convert("RGB")


# ------------------------------------------------------------------ main

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--shots", required=True, type=Path, help="実機スクリーンショットのフォルダ")
    ap.add_argument("--pages", required=True, type=Path, help="補正後ページ PNG (*_<photoId>.png)")
    ap.add_argument("--out", type=Path, default=ROOT / "docs" / "store")
    ap.add_argument("--readme", type=Path, default=ROOT / "docs" / "images")
    args = ap.parse_args()

    screens: dict[str, dict[str, Image.Image]] = {}
    for dev in (PHONE, TABLET):
        got = {}
        for kind, name in SHOTS[dev.name].items():
            shot = Image.open(args.shots / name)
            assert shot.size == dev.size, f"{name}: {shot.size} != {dev.size}"
            if kind == "camera":
                shot = camera_composite(shot, dev, "0003")
            elif kind == "crop":
                shot = crop_composite(shot, dev, "0093")
            got[kind] = clean(shot, dev, kind)
        screens[dev.name] = got
        # 合成した画面そのものも残す (確認用。大きいので build/ に)
        for kind in ("camera", "crop"):
            d = ROOT / "build" / "store_screens"
            d.mkdir(parents=True, exist_ok=True)
            got[kind].save(d / f"{dev.name}_{kind}.png", optimize=True)

    # 写真が多く PNG だと 1 枚 1〜3MB になるので、ストア用は高品質 JPEG (4:4:4) で保存する
    phone_slides: dict[str, Image.Image] = {}
    for target in TARGETS:
        out = args.out / target.folder
        out.mkdir(parents=True, exist_ok=True)
        for slide in SLIDES:
            if slide.screen and slide.screen not in screens[target.device.name]:
                continue
            img = render_slide(slide, target, screens[target.device.name], args.pages)
            assert img.size == target.size
            img.save(out / f"{slide.key}.jpg", quality=95, subsampling=0, optimize=True)
            if target.folder == "phone":
                phone_slides[slide.key] = img
            print(target.folder, slide.key, img.size)

    fg = feature_graphic(screens["phone"])
    fg.save(args.out / "feature_graphic.png", optimize=True)
    print("feature_graphic", fg.size)

    # README 用 (スマホ版を幅 540 の WebP に)
    args.readme.mkdir(parents=True, exist_ok=True)
    for key, img in phone_slides.items():
        img = img.resize((540, int(img.height * 540 / img.width)), Image.LANCZOS)
        img.save(args.readme / f"store_{key}.webp", "WEBP", quality=82, method=6)
    fg.resize((768, 375), Image.LANCZOS).save(args.readme / "store_feature.webp", "WEBP",
                                              quality=82, method=6)
    print("readme webp ->", args.readme)


if __name__ == "__main__":
    main()
