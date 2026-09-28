import 'dart:math' as math;
import 'dart:math' show Point;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'warper.dart';

/// 紙面 (白い用紙) の四隅を検出する純 Dart 実装。
///
/// 手順:
/// 1. 縮小して輝度化
/// 2. 大津の二値化で「明るい領域」を抽出 (楽譜の用紙はほぼ常に画面内で最も明るい大きな領域)
/// 3. モルフォロジー閉処理で穴を埋める
/// 4. 最大連結成分 (= 用紙) を取り出す
/// 5. 凸包 → 最大面積の四角形
/// 6. 四隅を [TL,TR,BR,BL] に並べて少し外側へパディング
class DocumentDetector {
  /// 輝度ヒューリスティック (大津) の四隅を外側へ広げる量 (短辺比)。
  /// 二値化で影側の縁が欠ける分の補正。
  static const double defaultCornerPad = 0.02;

  /// 紙面ネット (マスク → 四角形) の四隅を外側へ広げる量 (短辺比)。
  /// v2 のマスクは紙の縁に合わせて学習しているため広げない。学習に未使用の実写
  /// (training_data/eval_heldout, 紙あり 4 枚) で 0.02 → 0 にすると角誤差中央値が
  /// 1.80% → 1.46% (90 度回転版 2.20% → 1.82%) に改善した。
  static const double netCornerPad = 0.0;

  /// 紙面ネットのマスクにかけるオープニングの半径 (256x256 上の画素)。
  static const int netMaskOpenRadius = 0;

  /// 紙マスク (ネット出力) がこの割合未満なら「紙なし」とみなす。
  /// 画面の 5% 未満の紙はスキャンしても実用にならず、白い小物の誤検出を避ける。
  static const double minPaperMaskFraction = 0.05;

  /// 紙マスクがこの割合を超えたら「全面 = 紙なし (判定不能)」とみなす。
  static const double maxPaperMaskFraction = 0.99;

  /// マスク画素数 [maskSum] / 全画素数 [total] が紙として妥当な範囲か。
  static bool isPlausiblePaperMask(int maskSum, int total) =>
      maskSum >= total * minPaperMaskFraction &&
      maskSum <= total * maxPaperMaskFraction;

  /// 戻り値: 画像全体に対する正規化座標 (0..1) の四隅、検出失敗時は null。
  static List<Offset>? detect(img.Image source, {int workWidth = 320}) {
    img.Image small = source;
    if (source.width > workWidth) {
      small = img.copyResize(source,
          width: workWidth, interpolation: img.Interpolation.average);
    }
    final w = small.width;
    final h = small.height;
    final n = w * h;

    // --- 輝度化 ---
    final gray = Uint8List(n);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final px = small.getPixel(x, y);
        final r = px.r.toInt();
        final g = px.g.toInt();
        final b = px.b.toInt();
        gray[y * w + x] = ((r * 299 + g * 587 + b * 114) ~/ 1000).clamp(0, 255);
      }
    }
    return detectLuminance(gray, w, h, workWidth: w);
  }

  /// 2 値マスクの「穴」を埋める (背景 0 領域のうち画像の外周から
  /// 到達できない閉領域を前景化する)。文字・譜線で穴だらけになった
  /// セグメンテーションマスクを紙の実体に整形するために使う。
  /// 出力は 0/255 (detectLuminance の 0..255 輝度スケールに合わせる)。
  static Uint8List fillHoles(Uint8List mask, int w, int h) {
    if (w <= 0 || h <= 0 || mask.length < w * h) return mask;
    final background = Uint8List(w * h); // 1 = 未訪問の 0 領域
    for (int i = 0; i < w * h; i++) {
      background[i] = mask[i] == 0 ? 1 : 0;
    }
    final queue = Int32List(w * h);
    int head = 0, tail = 0;
    void seed(int idx) {
      if (background[idx] == 1) {
        background[idx] = 2; // 2 = 外周から到達した背景
        queue[tail++] = idx;
      }
    }

    for (int x = 0; x < w; x++) {
      seed(x);
      seed((h - 1) * w + x);
    }
    for (int y = 0; y < h; y++) {
      seed(y * w);
      seed(y * w + w - 1);
    }
    while (head < tail) {
      final idx = queue[head++];
      final x = idx % w;
      final y = idx ~/ w;
      if (x > 0 && background[idx - 1] == 1) {
        background[idx - 1] = 2;
        queue[tail++] = idx - 1;
      }
      if (x < w - 1 && background[idx + 1] == 1) {
        background[idx + 1] = 2;
        queue[tail++] = idx + 1;
      }
      if (y > 0 && background[idx - w] == 1) {
        background[idx - w] = 2;
        queue[tail++] = idx - w;
      }
      if (y < h - 1 && background[idx + w] == 1) {
        background[idx + w] = 2;
        queue[tail++] = idx + w;
      }
    }
    final out = Uint8List(w * h);
    for (int i = 0; i < w * h; i++) {
      // 外周から到達できなかった 0 領域 (= 穴) は前景にする
      out[i] = background[i] == 2 ? 0 : 255;
    }
    return out;
  }

  /// img.Image を輝度配列 (row-major w×h) に変換する。
  static Uint8List toGray(img.Image image) {
    final w = image.width;
    final h = image.height;
    final gray = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final px = image.getPixel(x, y);
        final r = px.r.toInt();
        final g = px.g.toInt();
        final b = px.b.toInt();
        gray[y * w + x] = ((r * 299 + g * 587 + b * 114) ~/ 1000).clamp(0, 255);
      }
    }
    return gray;
  }

  /// 輝度配列 (Y平面など, row-major w×h) から直接検出する。
  /// カメラの画像ストリーム (YUV の Y 平面) を変換なしで処理するための入口。
  /// [workWidth] 幅以下に整数間引きしてから判定する。
  static List<Offset>? detectLuminance(
    Uint8List gray,
    int w,
    int h, {
    int workWidth = 320,
    bool paperChecks = true,
    double pad = defaultCornerPad,
  }) {
    if (w <= 0 || h <= 0 || gray.length < w * h) return null;
    // 整数間引き (nearest) で作業サイズへ縮小
    final k = w > workWidth ? (w / workWidth).ceil() : 1;
    if (k > 1) {
      final dw = w ~/ k;
      final dh = h ~/ k;
      if (dw < 64 || dh < 64) {
        return detectLuminance(gray, w, h,
            workWidth: w, paperChecks: paperChecks, pad: pad);
      }
      final small = Uint8List(dw * dh);
      for (int y = 0; y < dh; y++) {
        final srcRow = y * k * w;
        final dstRow = y * dw;
        for (int x = 0; x < dw; x++) {
          small[dstRow + x] = gray[srcRow + x * k];
        }
      }
      return _detectFromGray(small, dw, dh, paperChecks: paperChecks, pad: pad);
    }
    return _detectFromGray(gray, w, h, paperChecks: paperChecks, pad: pad);
  }

  /// 輝度配列からの検出本体。
  static List<Offset>? _detectFromGray(Uint8List gray, int w, int h,
      {bool paperChecks = true, double pad = defaultCornerPad}) {
    final n = w * h;

    // --- 大津の二値化 ---
    final thresh = _otsuThreshold(gray);
    final bin = Uint8List(n);
    int fg = 0;
    for (int i = 0; i < n; i++) {
      if (gray[i] > thresh) {
        bin[i] = 1;
        fg++;
      }
    }
    // 前景が極端に少ない / ほぼ全部の場合は判定不能
    if (kDebugMode) {
      debugPrint('DetectTrace: otsu=$thresh fg=${(fg / n * 100).toStringAsFixed(1)}%');
    }
    if (fg < n * 0.05 || fg > n * 0.97) {
      if (kDebugMode) debugPrint('DetectTrace: FAIL fg ratio');
      return null;
    }

    // --- 閉処理 (dilate → erode) で文字・譜線の隙間を埋める ---
    final closed = _erode(_dilate(bin, w, h, 2), w, h, 2);

    // --- 最大連結成分 ---
    final region = _largestComponent(closed, w, h);
    if (kDebugMode) {
      debugPrint('DetectTrace: largest comp=${region == null ? 0 : (region.length / n * 100).toStringAsFixed(1)}%');
    }
    if (region == null || region.length < n * 0.12) {
      if (kDebugMode) debugPrint('DetectTrace: FAIL component < 12%');
      return null;
    }

    // --- 凸包 → 最大面積四角形 ---
    final hull = _convexHull(region);
    if (hull.length < 4) return null;
    final quadPts = _maxAreaQuad(hull);
    if (quadPts == null) return null;

    var corners = _orderCorners(quadPts);
    if (corners == null || !_isSaneQuad(corners, w, h)) return null;

    // 紙らしさ検査: 枠の内側が外側より明るく、4辺に実際のエッジが沿っている。
    // (明るい机など「紙のない」明部塊を誤検出しないためのゲート)
    if (paperChecks && !_passesPaperChecks(gray, w, h, corners)) return null;

    // 用紙の縁が影で欠ける分を見越してわずかに外側へ (短辺比 [pad])
    if (pad != 0) corners = _padCorners(corners, w, h, pad);

    return <Offset>[
      for (final c in corners) Offset(c.x / w, c.y / h),
    ];
  }

  // ---------------------------------------------------------------- 閾値

  static int _otsuThreshold(Uint8List gray) {
    final hist = List<int>.filled(256, 0);
    for (final v in gray) {
      hist[v]++;
    }
    final total = gray.length;
    double sumAll = 0;
    for (int i = 0; i < 256; i++) {
      sumAll += i * hist[i];
    }
    double sumB = 0;
    int wB = 0;
    double best = -1;
    int bestT = 128;
    for (int t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sumAll - sumB) / wF;
      final between = wB * wF * (mB - mF) * (mB - mF);
      if (between > best) {
        best = between;
        bestT = t;
      }
    }
    return bestT;
  }

  // -------------------------------------------------- モルフォロジー (分離可能)

  /// 2 値マスク (0/255) のオープニング (半径 [r] の収縮 → 膨張)。
  /// 紙のマスクに細い首でつながった「はみ出し」を切り離し、四角形の当てはめが
  /// はみ出しの先端に引っ張られるのを防ぐ。r <= 0 なら何もしない。
  static Uint8List openMask(Uint8List mask, int w, int h, int r) {
    if (r <= 0) return mask;
    final bin = Uint8List(w * h);
    for (int i = 0; i < w * h; i++) {
      bin[i] = mask[i] > 0 ? 1 : 0; // _erode/_dilate は 0/1 前提
    }
    final opened = _dilate(_erode(bin, w, h, r), w, h, r);
    final out = Uint8List(w * h);
    for (int i = 0; i < w * h; i++) {
      out[i] = opened[i] > 0 ? 255 : 0;
    }
    return out;
  }

  static Uint8List _dilate(Uint8List src, int w, int h, int r) =>
      _minMax(src, w, h, r, true);

  static Uint8List _erode(Uint8List src, int w, int h, int r) =>
      _minMax(src, w, h, r, false);

  static Uint8List _minMax(Uint8List src, int w, int h, int r, bool isMax) {
    final tmp = Uint8List(src.length);
    final out = Uint8List(src.length);
    // 水平
    for (int y = 0; y < h; y++) {
      final row = y * w;
      for (int x = 0; x < w; x++) {
        int v = isMax ? 0 : 1;
        for (int dx = -r; dx <= r; dx++) {
          final xx = (x + dx).clamp(0, w - 1);
          final s = src[row + xx];
          v = isMax ? (s > v ? s : v) : (s < v ? s : v);
        }
        tmp[row + x] = v;
      }
    }
    // 垂直
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        int v = isMax ? 0 : 1;
        for (int dy = -r; dy <= r; dy++) {
          final yy = (y + dy).clamp(0, h - 1);
          final s = tmp[yy * w + x];
          v = isMax ? (s > v ? s : v) : (s < v ? s : v);
        }
        out[y * w + x] = v;
      }
    }
    return out;
  }

  // ---------------------------------------------------------- 連結成分 (BFS)

  static List<Point<double>>? _largestComponent(Uint8List bin, int w, int h) {
    final visited = Uint8List(bin.length);
    final queue = Int32List(bin.length);
    List<Point<double>>? best;
    for (int start = 0; start < bin.length; start++) {
      if (bin[start] == 0 || visited[start] == 1) continue;
      int head = 0, tail = 0;
      queue[tail++] = start;
      visited[start] = 1;
      final comp = <Point<double>>[];
      while (head < tail) {
        final idx = queue[head++];
        final x = idx % w;
        final y = idx ~/ w;
        comp.add(Point<double>(x.toDouble(), y.toDouble()));
        if (x > 0 && bin[idx - 1] == 1 && visited[idx - 1] == 0) {
          visited[idx - 1] = 1;
          queue[tail++] = idx - 1;
        }
        if (x < w - 1 && bin[idx + 1] == 1 && visited[idx + 1] == 0) {
          visited[idx + 1] = 1;
          queue[tail++] = idx + 1;
        }
        if (y > 0 && bin[idx - w] == 1 && visited[idx - w] == 0) {
          visited[idx - w] = 1;
          queue[tail++] = idx - w;
        }
        if (y < h - 1 && bin[idx + w] == 1 && visited[idx + w] == 0) {
          visited[idx + w] = 1;
          queue[tail++] = idx + w;
        }
      }
      if (best == null || comp.length > best.length) best = comp;
    }
    return best;
  }

  // ---------------------------------------------------------------- 凸包

  static List<Point<double>> _convexHull(List<Point<double>> pts) {
    final sorted = List<Point<double>>.from(pts)
      ..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
    final n = sorted.length;
    if (n < 3) return sorted;

    final lower = <Point<double>>[];
    for (final p in sorted) {
      while (lower.length >= 2 &&
          _cross(lower[lower.length - 2], lower.last, p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }
    final upper = <Point<double>>[];
    for (int i = n - 1; i >= 0; i--) {
      final p = sorted[i];
      while (upper.length >= 2 &&
          _cross(upper[upper.length - 2], upper.last, p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }
    lower.removeLast();
    upper.removeLast();
    return <Point<double>>[...lower, ...upper];
  }

  // ------------------------------------------------- 凸包から最大面積の四角形

  static List<Point<double>>? _maxAreaQuad(List<Point<double>> hull) {
    // 計算量 O(m^3) を抑えるため点数を絞る
    final pts = _subsample(hull, 90);
    final m = pts.length;
    if (m < 4) return null;
    double best = 0;
    int bi = 0, bj = 0, bk = 0, bl = 0;
    for (int i = 0; i < m - 1; i++) {
      for (int j = i + 1; j < m; j++) {
        double maxPos = 0, maxNeg = 0;
        int kBest = -1, lBest = -1;
        for (int k = 0; k < m; k++) {
          if (k == i || k == j) continue;
          final cr = _cross(pts[i], pts[j], pts[k]);
          if (cr > maxPos) {
            maxPos = cr;
            kBest = k;
          } else if (-cr > maxNeg) {
            maxNeg = -cr;
            lBest = k;
          }
        }
        if (kBest < 0 || lBest < 0 || kBest == lBest) continue;
        final area = (maxPos + maxNeg) / 2;
        if (area > best) {
          best = area;
          bi = i;
          bj = j;
          bk = kBest;
          bl = lBest;
        }
      }
    }
    if (best <= 0) return null;
    return <Point<double>>[pts[bi], pts[bj], pts[bk], pts[bl]];
  }

  static List<Point<double>> _subsample(List<Point<double>> pts, int maxCount) {
    if (pts.length <= maxCount) return pts;
    final step = pts.length / maxCount;
    return <Point<double>>[
      for (int i = 0; i < maxCount; i++) pts[(i * step).floor().clamp(0, pts.length - 1)],
    ];
  }

  // -------------------------------------------------------------- ユーティリティ

  static double _cross(Point<double> a, Point<double> b, Point<double> c) =>
      (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);

  /// 4 点を [TL, TR, BR, BL] 順に並べ替える。退化時は null。
  static List<Point<double>>? _orderCorners(List<Point<double>> q) {
    Point<double>? tl, tr, br, bl;
    double dTL = double.infinity, dTR = -double.infinity;
    double dBR = -double.infinity, dBL = double.infinity;
    for (final p in q) {
      final s = p.x + p.y;
      final d = p.x - p.y;
      if (s < dTL) {
        dTL = s;
        tl = p;
      }
      if (s > dBR) {
        dBR = s;
        br = p;
      }
      if (d > dTR) {
        dTR = d;
        tr = p;
      }
      if (d < dBL) {
        dBL = d;
        bl = p;
      }
    }
    final distinct = <Point<double>?>{tl, tr, br, bl};
    if (distinct.length != 4 || distinct.contains(null)) return null;
    return <Point<double>>[tl!, tr!, br!, bl!];
  }

  /// 面積・辺長・凸性の妥当性チェック。
  static bool _isSaneQuad(List<Point<double>> q, int w, int h) {
    double polyArea = 0;
    for (int i = 0; i < 4; i++) {
      final a = q[i];
      final b = q[(i + 1) % 4];
      polyArea += a.x * b.y - b.x * a.y;
    }
    polyArea = polyArea.abs() / 2;
    if (polyArea < w * h * 0.08) return false;
    final minSide = math.max(w, h) * 0.18;
    for (int i = 0; i < 4; i++) {
      final d = (q[(i + 1) % 4]).distanceTo(q[i]);
      if (d < minSide) return false;
    }
    final asOffset = <Offset>[for (final p in q) Offset(p.x, p.y)];
    return isConvexQuad(asOffset);
  }

  /// 枠が「紙」かどうかの検査:
  /// - 内外コントラスト: 枠内側の輝度が外側より一定以上明るい (紙は白い)
  /// - エッジ支持: 4辺の各サンプル点で法線方向に輝度ステップがある
  static bool _passesPaperChecks(
      Uint8List gray, int w, int h, List<Point<double>> corners) {
    const samplesPerEdge = 18;
    const gradThresh = 18.0;
    const minContrast = 10.0;
    const minEdgeSupport = 0.5;

    final d = (math.min(w, h) * 0.04).clamp(4.0, 16.0);
    double inSum = 0, outSum = 0;
    int supported = 0, total = 0;
    for (int e = 0; e < 4; e++) {
      final a = corners[e];
      final b = corners[(e + 1) % 4];
      var nx = a.y - b.y; // 時計回り多角形の内向き法線 (y下向き座標系)
      var ny = b.x - a.x;
      final len = math.sqrt(nx * nx + ny * ny);
      if (len == 0) continue;
      nx /= len;
      ny /= len;
      for (int i = 2; i < samplesPerEdge - 2; i++) {
        final t = i / (samplesPerEdge - 1);
        final px = a.x + (b.x - a.x) * t;
        final py = a.y + (b.y - a.y) * t;
        int sx(double v, int maxV) => v.round().clamp(0, maxV);
        final inV = gray[sx(py + ny * d, h - 1) * w + sx(px + nx * d, w - 1)];
        final outV = gray[sx(py - ny * d, h - 1) * w + sx(px - nx * d, w - 1)];
        inSum += inV;
        outSum += outV;
        final g1 = gray[sx(py + ny * 1.5, h - 1) * w + sx(px + nx * 1.5, w - 1)];
        final g2 = gray[sx(py - ny * 1.5, h - 1) * w + sx(px - nx * 1.5, w - 1)];
        if ((g1 - g2).abs() > gradThresh) supported++;
        total++;
      }
    }
    if (total == 0) return false;
    final contrast = inSum / total - outSum / total;
    return contrast > minContrast && supported / total >= minEdgeSupport;
  }


  /// 四隅のアンカーを写真の実際のエッジ (法線方向の明暗差) にスナップする。
  ///
  /// 各辺ごとに法線方向へ走査し、現位置に最も近い「優勢な」勾配ピーク
  /// (閾値以上かつ窓内最大値の 60% 以上) の位置へ辺全体を平行移動。
  /// 移動した隣接辺の交点から新しい四隅を作る。
  /// 最強ピークではなく最近接ピークを選ぶのは、アンカーが既に正しい場合に
  /// より強い競合エッジ (影・周辺物) へ飛びつくのを防ぐため。
  /// サンプルの過半がピークを検出できなければ辺は動かない。
  /// 戻り値は入力と同じ正規化座標系。
  static List<Offset> snapQuadToEdges(List<Offset> quad, Uint8List gray, int w, int h,
      {double searchRatio = 0.035, double minContrast = 12}) {
    if (quad.length != 4 || w <= 0 || h <= 0) return quad;
    final radius = (math.min(w, h) * searchRatio).clamp(6.0, 40.0);
    final cx = (quad[0].dx + quad[1].dx + quad[2].dx + quad[3].dx) / 4;
    final cy = (quad[0].dy + quad[1].dy + quad[2].dy + quad[3].dy) / 4;

    // ピクセル座標へ
    final px = [for (final q in quad) Offset(q.dx * w, q.dy * h)];

    // 辺ごとの (代表点1, 代表点2) — 移動後の辺を定義する
    final linePts = <List<Offset>>[];
    for (int i = 0; i < 4; i++) {
      final a = px[i];
      final b = px[(i + 1) % 4];
      var ex = b.dx - a.dx;
      var ey = b.dy - a.dy;
      final elen = math.sqrt(ex * ex + ey * ey);
      if (elen < 1) {
        linePts.add([a, b]);
        continue;
      }
      ex /= elen;
      ey /= elen;
      var nx = ey;
      var ny = -ex;
      final midX = (a.dx + b.dx) / 2;
      final midY = (a.dy + b.dy) / 2;
      // 法線を四隅の重心から外向きに統一 (スナップ方向の一貫性のため)
      if (nx * (midX - cx) + ny * (midY - cy) < 0) {
        nx = -nx;
        ny = -ny;
      }
      final offs = <double>[];
      final radiusInt = radius.round();
      final nD = 2 * radiusInt + 1;
      final gs = List<double>.filled(nD, 0);
      for (int k = 2; k <= 22; k++) {
        final t = k / 24;
        final ppx = a.dx + (b.dx - a.dx) * t;
        final ppy = a.dy + (b.dy - a.dy) * t;
        for (int di = 0; di < nD; di++) {
          final d = (di - radiusInt).toDouble();
          final g1 = _grayAt(gray, w, h, ppx + (d + 1) * nx, ppy + (d + 1) * ny);
          final g2 = _grayAt(gray, w, h, ppx + (d - 1) * nx, ppy + (d - 1) * ny);
          gs[di] = (g1 - g2).abs();
        }
        // 0 に最も近い「優勢な」勾配ピークへ寄せる。
        // 全窓の最強ピークにすると、アンカーが既に正しい場合でも
        // より強い競合エッジ (影・周辺物) へ飛びついてしまうため。
        double gMax = 0;
        for (final g in gs) {
          if (g > gMax) gMax = g;
        }
        if (gMax < minContrast) continue;
        final domi = gMax * 0.6; // これ未満のピークは机のノイズとして無視
        var bestD = double.nan;
        var bestG = 0.0;
        for (int di = 1; di < nD - 1; di++) {
          final g = gs[di];
          if (g < minContrast ||
              g < domi ||
              g < gs[di - 1] ||
              g < gs[di + 1]) {
            continue;
          }
          final d = (di - radiusInt).toDouble();
          if (bestD.isNaN ||
              d.abs() < bestD.abs() ||
              (d.abs() == bestD.abs() && g > bestG)) {
            bestD = d;
            bestG = g;
          }
        }
        if (!bestD.isNaN) {
          offs.add(bestD);
        }
      }
      // オフセットは中央値でロバスト化 (外れ値に強い)
      var dHat = 0.0;
      if (offs.length >= 5) {
        offs.sort();
        dHat = offs[offs.length ~/ 2];
      }
      linePts.add([
        Offset(a.dx + dHat * nx, a.dy + dHat * ny),
        Offset(b.dx + dHat * nx, b.dy + dHat * ny),
      ]);
    }

    // 隣接辺の交点から新しい四隅
    final out = <Offset>[];
    for (int i = 0; i < 4; i++) {
      final prev = linePts[(i + 3) % 4];
      final cur = linePts[i];
      final ip = _lineIntersect(prev[0], prev[1], cur[0], cur[1]);
      if (ip == null) {
        out.add(px[i]);
      } else {
        out.add(Offset(
            ip.dx.clamp(0.0, w - 1.0), ip.dy.clamp(0.0, h - 1.0)));
      }
    }
    return [for (final p in out) Offset(p.dx / w, p.dy / h)];
  }

  static double _grayAt(Uint8List gray, int w, int h, double x, double y) {
    final xi = x.round().clamp(0, w - 1);
    final yi = y.round().clamp(0, h - 1);
    return gray[yi * w + xi].toDouble();
  }

  static Offset? _lineIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
    final d1x = p2.dx - p1.dx;
    final d1y = p2.dy - p1.dy;
    final d2x = p4.dx - p3.dx;
    final d2y = p4.dy - p3.dy;
    final den = d1x * d2y - d1y * d2x;
    if (den.abs() < 1e-9) return null;
    final t = ((p3.dx - p1.dx) * d2y - (p3.dy - p1.dy) * d2x) / den;
    return Offset(p1.dx + t * d1x, p1.dy + t * d1y);
  }

  /// 重心から外側へ pad (画像短辺比) だけ膨らませる。
  static List<Point<double>> _padCorners(List<Point<double>> q, int w, int h, double pad) {
    double sx = 0, sy = 0;
    for (final p in q) {
      sx += p.x;
      sy += p.y;
    }
    final cx = sx / 4;
    final cy = sy / 4;
    final amount = pad * math.min(w, h);
    return <Point<double>>[
      for (final p in q)
        () {
          final vx = p.x - cx;
          final vy = p.y - cy;
          final len = math.sqrt(vx * vx + vy * vy).clamp(1e-6, double.infinity).toDouble();
          final nx = (cx + vx / len * (len + amount)).toDouble();
          final ny = (cy + vy / len * (len + amount)).toDouble();
          return Point(nx.clamp(0, w - 1).toDouble(), ny.clamp(0, h - 1).toDouble());
        }(),
    ];
  }
}
