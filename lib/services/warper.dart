import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// 4 点対応からホモグラフィ (3x3 射影変換) を解き、
/// 逆変換しながら矩形へ再サンプリング (台形補正) する純 Dart 実装。

/// 単位: ピクセル座標のまま扱う。h[8] = 1 に正規化した DLT。
class Homography {
  Homography._(this.m);

  /// m = [m00 m01 m02 m10 m11 m12 m20 m21 m22]
  final Float64List m;

  /// src[4] -> dst[4] を満たす変換を求める。
  static Homography fromPoints(List<Offset> src, List<Offset> dst) {
    final a = Float64List(64);
    final b = Float64List(8);
    for (int i = 0; i < 4; i++) {
      final x = src[i].dx, y = src[i].dy;
      final u = dst[i].dx, v = dst[i].dy;
      final r0 = i * 2, r1 = i * 2 + 1;
      a[r0 * 8 + 0] = x;
      a[r0 * 8 + 1] = y;
      a[r0 * 8 + 2] = 1;
      a[r0 * 8 + 6] = -u * x;
      a[r0 * 8 + 7] = -u * y;
      b[r0] = u;
      a[r1 * 8 + 3] = x;
      a[r1 * 8 + 4] = y;
      a[r1 * 8 + 5] = 1;
      a[r1 * 8 + 6] = -v * x;
      a[r1 * 8 + 7] = -v * y;
      b[r1] = v;
    }
    final h = _solve8(a, b);
    if (h == null) {
      // 退化 (ほぼ一直線など) 時のフォールバック: 恒等変換

      return Homography._(Float64List.fromList(<double>[1, 0, 0, 0, 1, 0, 0, 0, 1]));
    }
    return Homography._(h);
  }

  /// ガウス消去 (部分ピボット) で 8 元連立を解く。
  static Float64List? _solve8(Float64List a, Float64List b) {
    final n = 8;
    // 拡大係数行列
    final aug = Float64List(n * (n + 1));
    for (int r = 0; r < n; r++) {
      for (int c = 0; c < n; c++) {
        aug[r * (n + 1) + c] = a[r * n + c];
      }
      aug[r * (n + 1) + n] = b[r];
    }
    for (int col = 0; col < n; col++) {
      // ピボット選択
      int piv = col;
      double best = aug[col * (n + 1) + col].abs();
      for (int r = col + 1; r < n; r++) {
        final v = aug[r * (n + 1) + col].abs();
        if (v > best) {
          best = v;
          piv = r;
        }
      }
      if (best < 1e-12) return null;
      if (piv != col) {
        for (int c = col; c <= n; c++) {
          final t = aug[col * (n + 1) + c];
          aug[col * (n + 1) + c] = aug[piv * (n + 1) + c];
          aug[piv * (n + 1) + c] = t;
        }
      }
      // 前進消去
      final d = aug[col * (n + 1) + col];
      for (int r = 0; r < n; r++) {
        if (r == col) continue;
        final f = aug[r * (n + 1) + col] / d;
        if (f == 0) continue;
        for (int c = col; c <= n; c++) {
          aug[r * (n + 1) + c] -= f * aug[col * (n + 1) + c];
        }
      }
    }
    final x = Float64List(n);
    for (int r = 0; r < n; r++) {
      x[r] = aug[r * (n + 1) + n] / aug[r * (n + 1) + r];
    }
    return Float64List.fromList(<double>[x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7], 1]);
  }

  Offset apply(Offset p) {
    final w = m[6] * p.dx + m[7] * p.dy + m[8];
    return Offset(
      (m[0] * p.dx + m[1] * p.dy + m[2]) / w,
      (m[3] * p.dx + m[4] * p.dy + m[5]) / w,
    );
  }

  /// 逆変換 (随伴行列 / 行列式)。
  Homography inverse() {
    final m = this.m;
    final a = m[0], b = m[1], c = m[2];
    final d = m[3], e = m[4], f = m[5];
    final g = m[6], h = m[7], i = m[8];
    final c11 = e * i - f * h;
    final c12 = f * g - d * i;
    final c13 = d * h - e * g;
    final det = a * c11 + b * c12 + c * c13;
    if (det.abs() < 1e-12) {
      return Homography._(Float64List.fromList(<double>[1, 0, 0, 0, 1, 0, 0, 0, 1]));
    }
    final inv = Float64List(9);
    inv[0] = c11 / det;
    inv[1] = (c * h - b * i) / det;
    inv[2] = (b * f - c * e) / det;
    inv[3] = c12 / det;
    inv[4] = (a * i - c * g) / det;
    inv[5] = (c * d - a * f) / det;
    inv[6] = c13 / det;
    inv[7] = (b * g - a * h) / det;
    inv[8] = (a * e - b * d) / det;
    return Homography._(inv);
  }
}

/// 出力画像サイズを四角形の辺長から決める (長辺 maxSide に収める)。
/// corners は [TL, TR, BR, BL] の順。
Size outputSizeForQuad(List<Offset> corners,
    {int maxSide = 2400, int minSide = 420}) {
  double len(Offset a, Offset b) => (a - b).distance;
  final top = len(corners[0], corners[1]);
  final bottom = len(corners[3], corners[2]);
  final left = len(corners[0], corners[3]);
  final right = len(corners[1], corners[2]);
  var w = (top + bottom) / 2;
  var h = (left + right) / 2;
  if (w < minSide && h < minSide) {
    final s = minSide / math.max(w, h).clamp(1e-6, double.infinity);
    w *= s;
    h *= s;
  }
  final longSide = math.max(w, h);
  if (longSide > maxSide) {
    final s = maxSide / longSide;
    w *= s;
    h *= s;
  }
  return Size(w.round().clamp(16, 6000).toDouble(),
      h.round().clamp(16, 6000).toDouble());
}

/// 台形補正本体。RGB (3ch) の出力を返す。
/// [srcQuad] は [TL, TR, BR, BL] 順のソース画像上の座標。
/// 範囲外の画素は白で埋める。
Uint8List warpPerspectiveRgb({
  required Uint8List src,
  required int srcW,
  required int srcH,
  required int numCh,
  required List<Offset> srcQuad,
  required int outW,
  required int outH,
}) {
  final dstQuad = <Offset>[
    Offset.zero,
    Offset(outW.toDouble(), 0),
    Offset(outW.toDouble(), outH.toDouble()),
    Offset(0, outH.toDouble()),
  ];
  // 出力 -> ソース の逆写像
  final inv = Homography.fromPoints(dstQuad, srcQuad);
  final out = Uint8List(outW * outH * 3);
  for (int y = 0; y < outH; y++) {
    for (int x = 0; x < outW; x++) {
      final p = inv.apply(Offset(x + 0.5, y + 0.5));
      final sx = p.dx - 0.5;
      final sy = p.dy - 0.5;
      final oi = (y * outW + x) * 3;
      if (sx < -1 || sy < -1 || sx > srcW || sy > srcH) {
        out[oi] = 255;
        out[oi + 1] = 255;
        out[oi + 2] = 255;
        continue;
      }
      final x0 = sx.floor();
      final y0 = sy.floor();
      final fx = sx - x0;
      final fy = sy - y0;
      final cx0 = x0.clamp(0, srcW - 1);
      final cy0 = y0.clamp(0, srcH - 1);
      final cx1 = (x0 + 1).clamp(0, srcW - 1);
      final cy1 = (y0 + 1).clamp(0, srcH - 1);
      final rx0 = cy0 * srcW;
      final rx1 = cy1 * srcW;
      for (int c = 0; c < 3; c++) {
        final i00 = (rx0 + cx0) * numCh + c;
        final i10 = (rx0 + cx1) * numCh + c;
        final i01 = (rx1 + cx0) * numCh + c;
        final i11 = (rx1 + cx1) * numCh + c;
        final p00 = src[i00].toDouble();
        final p10 = src[i10].toDouble();
        final p01 = src[i01].toDouble();
        final p11 = src[i11].toDouble();
        final v = p00 * (1 - fx) * (1 - fy) +
            p10 * fx * (1 - fy) +
            p01 * (1 - fx) * fy +
            p11 * fx * fy;
        out[oi + c] = v.round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// 凸四角形かどうか (頂点順 [TL,TR,BR,BL])。
bool isConvexQuad(List<Offset> q) {
  double cross(Offset a, Offset b, Offset c) =>
      (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
  final s1 = cross(q[0], q[1], q[2]);
  final s2 = cross(q[1], q[2], q[3]);
  final s3 = cross(q[2], q[3], q[0]);
  final s4 = cross(q[3], q[0], q[1]);
  final hasPos = s1 > 0 || s2 > 0 || s3 > 0 || s4 > 0;
  final hasNeg = s1 < 0 || s2 < 0 || s3 < 0 || s4 < 0;
  return !(hasPos && hasNeg);
}
