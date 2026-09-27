import 'dart:typed_data';

/// 色域を分析してパレット数を自動決定し、画像を減色する純 Dart 実装。
///
/// 処理は isolate 上 (`_prepareScanData`) で動くことを想定しているため
/// Flutter / dart:ui に依存しない。
///
/// 手順:
/// 1. [decidePaletteSize]: サンプリングした色のユニーク数と彩色ピクセル比率
///    (色域の「にぎやかさ」) からパレット数を自動決定
/// 2. [quantize]: RGB を 5bit/チャンネル (32768 バケット) に集計し、
///    メディアンカットでパレットを作り、全ピクセルを最近傍パレット色へ置換
class ColorQuantizer {
  ColorQuantizer._();

  static const int _bucketBits = 5;
  static const int _bucketShift = 8 - _bucketBits; // 3
  static const int _bucketCount = 1 << (_bucketBits * 3); // 32768

  /// 自動モードのパレット数上限。
  static const int maxAutoColors = 32;

  /// 画像 (RGB 3 バイト/px) の色域を分析し、使うべきパレット数を返す (2..32)。
  ///
  /// - ユニーク色が少なければその数をそのまま使う (ほぼ劣化なし)
  /// - 無彩色寄り (楽譜の白黒 + 印) なら 8 色
  /// - 中程度の彩色なら 16 色、カラフルなら 32 色
  static int decidePaletteSize(Uint8List rgb, {int sampleStride = 12}) {
    final stride = 3 * (sampleStride < 1 ? 1 : sampleStride);
    final seen = Uint8List(_bucketCount);
    int distinct = 0;
    int sampled = 0;
    int colorful = 0;
    for (int i = 0; i + 2 < rgb.length; i += stride) {
      final r = rgb[i];
      final g = rgb[i + 1];
      final b = rgb[i + 2];
      sampled++;
      final maxc = r > g ? (r > b ? r : b) : (g > b ? g : b);
      final minc = r < g ? (r < b ? r : b) : (g < b ? g : b);
      if (maxc - minc > 24) {
        colorful++;
      }
      final key = bucketKey(r, g, b);
      if (seen[key] == 0) {
        seen[key] = 1;
        distinct++;
      }
    }
    if (sampled == 0) return maxAutoColors;
    final colorfulFrac = colorful / sampled;
    // 無彩色寄り (白黒文書) は色数に関係なく 8 色で十分
    if (colorfulFrac < 0.04) return 8;
    // 色数が少ない画像はそのまま (ほぼ劣化なし)
    if (distinct <= 32) {
      return distinct < 2 ? 2 : distinct;
    }
    if (colorfulFrac < 0.18) return 16;
    return maxAutoColors;
  }

  /// 画像 (RGB 3 バイト/px) を in-place で [maxColors] 色以下に減色する。
  /// 元のユニーク色数が [maxColors] 以下なら何もしない (劣化なし)。
  static void quantize(Uint8List rgb, int maxColors) {
    if (maxColors < 2 || rgb.length < 3) return;

    // --- バケット集計 (5bit/チャンネル) ---
    final counts = Uint32List(_bucketCount);
    final sumR = Uint32List(_bucketCount);
    final sumG = Uint32List(_bucketCount);
    final sumB = Uint32List(_bucketCount);
    int stride = 3;
    final totalPx = rgb.length ~/ 3;
    if (totalPx > (1 << 21)) stride = 3 * 4; // 大画像は 4px ごとにサンプリング
    for (int i = 0; i + 2 < rgb.length; i += stride) {
      final key = bucketKey(rgb[i], rgb[i + 1], rgb[i + 2]);
      counts[key]++;
      sumR[key] += rgb[i];
      sumG[key] += rgb[i + 1];
      sumB[key] += rgb[i + 2];
    }

    final populated = <int>[];
    for (int k = 0; k < _bucketCount; k++) {
      if (counts[k] > 0) populated.add(k);
    }
    if (populated.isEmpty) return;

    // --- パレット構築 ---
    final palette = <int>[]; // 0xRRGGBB
    if (populated.length <= maxColors) {
      // バケット数が上限以下: バケットごとの平均色をそのままパレットにする
      // (平坦な色は完全保持、バケット内の近似色はマージされる)
      for (final k in populated) {
        final c = counts[k];
        palette.add(_rgb(
            (sumR[k] ~/ c).clamp(0, 255),
            (sumG[k] ~/ c).clamp(0, 255),
            (sumB[k] ~/ c).clamp(0, 255)));
      }
    } else {
      // メディアンカット
      final boxes = <_Box>[_makeBox(populated, counts)];
      while (boxes.length < maxColors) {
        _Box? best;
        int bestAxis = -1;
        int bestScore = -1;
        for (final box in boxes) {
          if (box.buckets.length < 2) continue;
          for (int axis = 0; axis < 3; axis++) {
            final range = _channelRange(box, axis, counts, sumR, sumG, sumB);
            if (range <= 0) continue;
            final score = range * box.count;
            if (score > bestScore) {
              bestScore = score;
              best = box;
              bestAxis = axis;
            }
          }
        }
        if (best == null) break;
        _splitBox(best, bestAxis, counts, sumR, sumG, sumB, boxes);
      }
      for (final box in boxes) {
        if (box.count == 0) continue;
        int sr = 0, sg = 0, sb = 0;
        for (final k in box.buckets) {
          sr += sumR[k];
          sg += sumG[k];
          sb += sumB[k];
        }
        palette.add(_rgb(
            (sr ~/ box.count).clamp(0, 255),
            (sg ~/ box.count).clamp(0, 255),
            (sb ~/ box.count).clamp(0, 255)));
      }
    }
    if (palette.isEmpty) return;

    // --- バケット → パレット番号の対応表 (-1 = 未計算) ---
    final map = Int16List(_bucketCount)..fillRange(0, _bucketCount, -1);
    for (final k in populated) {
      map[k] = _nearest(
        palette,
        _bucketCenter(k, 0, sumR, counts),
        _bucketCenter(k, 1, sumG, counts),
        _bucketCenter(k, 2, sumB, counts),
      );
    }

    // --- 全ピクセルをパレット色へ置換 ---
    for (int i = 0; i + 2 < rgb.length; i += 3) {
      final key = bucketKey(rgb[i], rgb[i + 1], rgb[i + 2]);
      var pi = map[key];
      if (pi < 0) {
        // 大画像の間引きサンプリングで集計されなかったバケット:
        // その画素色から最近傍を求めてキャッシュする
        pi = _nearest(palette, rgb[i], rgb[i + 1], rgb[i + 2]);
        map[key] = pi;
      }
      final pc = palette[pi];
      rgb[i] = (pc >> 16) & 0xFF;
      rgb[i + 1] = (pc >> 8) & 0xFF;
      rgb[i + 2] = pc & 0xFF;
    }
  }

  /// (r, g, b) に最も近いパレット色の番号。
  static int _nearest(List<int> palette, int r, int g, int b) {
    int bestIdx = 0;
    int bestDist = 1 << 30;
    for (int p = 0; p < palette.length; p++) {
      final pc = palette[p];
      final dr = r - ((pc >> 16) & 0xFF);
      final dg = g - ((pc >> 8) & 0xFF);
      final db = b - (pc & 0xFF);
      final dist = dr * dr + dg * dg + db * db;
      if (dist < bestDist) {
        bestDist = dist;
        bestIdx = p;
      }
    }
    return bestIdx;
  }

  static int bucketKey(int r, int g, int b) =>
      ((r >> _bucketShift) << (_bucketBits * 2)) |
      ((g >> _bucketShift) << _bucketBits) |
      (b >> _bucketShift);

  static int _bucketCenter(
      int bucket, int axis, Uint32List sums, Uint32List counts) {
    final c = counts[bucket];
    if (c == 0) return 0;
    return (sums[bucket] ~/ c).clamp(0, 255);
  }

  static int _rgb(int r, int g, int b) => (r << 16) | (g << 8) | b;

  static _Box _makeBox(List<int> buckets, Uint32List counts) {
    var count = 0;
    for (final k in buckets) {
      count += counts[k];
    }
    return _Box(buckets, count);
  }

  /// ボックス内の指定チャンネル (0=R,1=G,2=B) の平均値レンジ (max-min)。
  static int _channelRange(_Box box, int axis, Uint32List counts,
      Uint32List sumR, Uint32List sumG, Uint32List sumB) {
    int minV = 255;
    int maxV = -1;
    for (final k in box.buckets) {
      final c = counts[k];
      if (c == 0) continue;
      final sums = axis == 0 ? sumR : (axis == 1 ? sumG : sumB);
      final v = (sums[k] ~/ c).clamp(0, 255);
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    return maxV < 0 ? 0 : maxV - minV;
  }

  /// 指定軸の加重中央値でボックスを 2 つに分割し、後半を [boxes] に追加する。
  static void _splitBox(_Box box, int axis, Uint32List counts, Uint32List sumR,
      Uint32List sumG, Uint32List sumB, List<_Box> boxes) {
    int total = 0;
    for (final k in box.buckets) {
      total += counts[k];
    }
    final sorted = List<int>.of(box.buckets)
      ..sort((a, b) => _bucketCenter(a, axis, axis == 0
              ? sumR
              : axis == 1
                  ? sumG
                  : sumB, counts)
          .compareTo(_bucketCenter(b, axis, axis == 0
              ? sumR
              : axis == 1
                  ? sumG
                  : sumB, counts)));
    int acc = 0;
    int splitAt = -1;
    for (int i = 0; i < sorted.length - 1; i++) {
      acc += counts[sorted[i]];
      if (acc >= total ~/ 2) {
        splitAt = i + 1;
        break;
      }
    }
    if (splitAt <= 0 || splitAt >= sorted.length) {
      splitAt = sorted.length ~/ 2;
    }
    if (splitAt <= 0 || splitAt >= sorted.length) return;

    box.buckets = sorted.sublist(0, splitAt);
    box.count = _makeBox(box.buckets, counts).count;
    boxes.add(_makeBox(sorted.sublist(splitAt), counts));
  }
}

/// メディアンカットのボックス (バケット番号の集合 + 総ピクセル数)。
class _Box {
  _Box(this.buckets, this.count);

  List<int> buckets;
  int count;
}
