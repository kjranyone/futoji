import 'dart:typed_data';

/// RGB (3ch, 行優先) のバイト列を扱う小さな画像処理。
///
/// 保存処理の後段 (WebP 変換に渡す BMP とサムネイル) で使う。image パッケージの
/// 汎用処理 (img.Image を経由した encodeBmp / copyResize) は実機で長辺 2600px の
/// 画像に BMP 化 約 0.2 秒・縮小 約 0.4 秒かかっていたので、バイト列から直接作る。

/// 24bit 無圧縮 BMP (下から上の行順、行は 4 バイト境界に詰める) にする。
Uint8List encodeBmp24(Uint8List rgb, int w, int h) {
  final rowBytes = (w * 3 + 3) & ~3;
  const headerSize = 14 + 40;
  final size = headerSize + rowBytes * h;
  final out = Uint8List(size);
  final bd = ByteData.sublistView(out);
  // BITMAPFILEHEADER
  out[0] = 0x42; // 'B'
  out[1] = 0x4D; // 'M'
  bd.setUint32(2, size, Endian.little);
  bd.setUint32(10, headerSize, Endian.little);
  // BITMAPINFOHEADER
  bd.setUint32(14, 40, Endian.little);
  bd.setInt32(18, w, Endian.little);
  bd.setInt32(22, h, Endian.little); // 正 = 下から上
  bd.setUint16(26, 1, Endian.little); // planes
  bd.setUint16(28, 24, Endian.little); // bpp
  bd.setUint32(34, rowBytes * h, Endian.little);
  bd.setInt32(38, 2835, Endian.little); // 72dpi
  bd.setInt32(42, 2835, Endian.little);
  for (int y = 0; y < h; y++) {
    var si = y * w * 3;
    var di = headerSize + (h - 1 - y) * rowBytes;
    for (int x = 0; x < w; x++, si += 3, di += 3) {
      out[di] = rgb[si + 2];
      out[di + 1] = rgb[si + 1];
      out[di + 2] = rgb[si];
    }
  }
  return out;
}

/// 長辺が [maxSide] 以下になるよう、面積平均 (箱フィルタ) で縮小する。
/// 出力の各画素は、対応するソースの矩形 (整数境界) の平均。縮小不要ならそのまま返す。
(Uint8List, int, int) downscaleRgbBox(Uint8List rgb, int w, int h, int maxSide) {
  final long = w >= h ? w : h;
  if (long <= maxSide) return (rgb, w, h);
  final tw = w >= h ? maxSide : (w * maxSide / h).round().clamp(1, maxSide);
  final th = w >= h ? (h * maxSide / w).round().clamp(1, maxSide) : maxSide;
  // 出力の列 / 行が受け持つソースの範囲 [start[i], start[i + 1])
  final xs = Int32List(tw + 1);
  for (int i = 0; i <= tw; i++) {
    xs[i] = i * w ~/ tw;
  }
  final ys = Int32List(th + 1);
  for (int j = 0; j <= th; j++) {
    ys[j] = j * h ~/ th;
  }
  final out = Uint8List(tw * th * 3);
  final colSum = Int32List(w * 3); // 出力 1 行ぶんのソース行を列ごとに足したもの
  for (int j = 0; j < th; j++) {
    colSum.fillRange(0, w * 3, 0);
    final y0 = ys[j], y1 = ys[j + 1];
    for (int y = y0; y < y1; y++) {
      final o = y * w * 3;
      for (int i = 0; i < w * 3; i++) {
        colSum[i] += rgb[o + i];
      }
    }
    final rows = y1 - y0;
    for (int i = 0; i < tw; i++) {
      final x0 = xs[i], x1 = xs[i + 1];
      int r = 0, g = 0, b = 0;
      for (int x = x0; x < x1; x++) {
        r += colSum[x * 3];
        g += colSum[x * 3 + 1];
        b += colSum[x * 3 + 2];
      }
      final n = rows * (x1 - x0);
      final half = n >> 1;
      final oi = (j * tw + i) * 3;
      out[oi] = (r + half) ~/ n;
      out[oi + 1] = (g + half) ~/ n;
      out[oi + 2] = (b + half) ~/ n;
    }
  }
  return (out, tw, th);
}
