import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'staff_dewarp.dart';

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

/// 焦点距離が分からないときに使う 35mm 換算の焦点距離 (スマホの標準カメラの典型値)。
const double kDefaultFocal35mm = 28;

/// 35mm 換算の焦点距離を、幅 [imageW]・高さ [imageH] の画像上のピクセル単位に直す
/// (35mm 換算は対角 43.27mm の画角で定義される)。
double focalPxFrom35mm(double focal35, double imageW, double imageH) =>
    focal35 * math.sqrt(imageW * imageW + imageH * imageH) / 43.27;

/// 写真に写った四角形 [quad] ([TL, TR, BR, BL]、画像ピクセル座標) から、
/// 元の長方形の縦横比 (幅/高さ) を透視を考慮して推定する (Zhang & He 2006)。
///
/// 辺の長さの平均だと、斜めから撮ったときに奥行き方向が縮んで潰れる。
/// 主点は画像中心、焦点距離は [focalPx] (ピクセル) とする。
/// 四角形が退化していて解けないときは null。
double? estimateQuadAspect(List<Offset> quad,
    {required double imageW, required double imageH, required double focalPx}) {
  final cx = imageW / 2, cy = imageH / 2;
  List<double> h(Offset p) => <double>[p.dx - cx, p.dy - cy, 1];
  List<double> cross(List<double> a, List<double> b) => <double>[
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
      ];
  double dot(List<double> a, List<double> b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

  // 論文の記法: m1=左上, m2=右上, m3=左下, m4=右下
  final m1 = h(quad[0]), m2 = h(quad[1]), m3 = h(quad[3]), m4 = h(quad[2]);
  final c14 = cross(m1, m4);
  final d2 = dot(cross(m2, m4), m3);
  final d3 = dot(cross(m3, m4), m2);
  if (d2.abs() < 1e-9 || d3.abs() < 1e-9) return null;
  final k2 = dot(c14, m3) / d2;
  final k3 = dot(c14, m2) / d3;
  // 幅方向・高さ方向の辺に対応するベクトル (カメラ座標で長方形の辺に比例)
  final n2 = <double>[for (var i = 0; i < 3; i++) k2 * m2[i] - m1[i]];
  final n3 = <double>[for (var i = 0; i < 3; i++) k3 * m3[i] - m1[i]];
  final f2 = focalPx * focalPx;
  final w2 = n2[0] * n2[0] + n2[1] * n2[1] + f2 * n2[2] * n2[2];
  final h2 = n3[0] * n3[0] + n3[1] * n3[1] + f2 * n3[2] * n3[2];
  if (!(w2 > 0) || !(h2 > 0)) return null;
  final r = math.sqrt(w2 / h2);
  return r.isFinite ? r : null;
}

/// 推定した縦横比 [aspect] (幅/高さ) が A 判・B 判の比率 (√2) に近ければ √2 ちょうどにする。
/// 楽譜はほぼ A4・B4 なので、四隅の誤差による数 % のぶれを吸収できる。向き (縦長/横長) は保つ。
double snapToPaperAspect(double aspect, {double tolerance = 0.05}) {
  final long = aspect >= 1 ? aspect : 1 / aspect;
  if ((long / math.sqrt2 - 1).abs() > tolerance) return aspect;
  return aspect >= 1 ? math.sqrt2 : 1 / math.sqrt2;
}

/// 出力画像サイズを四角形の辺長から決める (長辺 maxSide に収める)。
/// corners は [TL, TR, BR, BL] の順。
/// [aspect] (幅/高さ) を与えると、辺長の平均のうち縮んで写っている側を伸ばしてその比率にする。
Size outputSizeForQuad(List<Offset> corners,
    {int maxSide = 2400, int minSide = 420, double? aspect}) {
  double len(Offset a, Offset b) => (a - b).distance;
  final top = len(corners[0], corners[1]);
  final bottom = len(corners[3], corners[2]);
  final left = len(corners[0], corners[3]);
  final right = len(corners[1], corners[2]);
  var w = (top + bottom) / 2;
  var h = (left + right) / 2;
  if (aspect != null && aspect > 0 && h > 0) {
    if (w / h < aspect) {
      w = h * aspect;
    } else {
      h = w / aspect;
    }
  }
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
/// [dewarp] があれば、台形補正後の画像にかける湾曲補正 (縦方向の変位) を
/// 逆写像に合成し、ソースから 1 回だけ再サンプリングする。
Uint8List warpPerspectiveRgb({
  required Uint8List src,
  required int srcW,
  required int srcH,
  required int numCh,
  required List<Offset> srcQuad,
  required int outW,
  required int outH,
  PageDewarp? dewarp,
}) =>
    _warp(src, srcW, srcH, numCh, srcQuad, outW, outH, dewarp, gray: false);

/// [warpPerspectiveRgb] と同じ台形補正で、輝度 (BT.601) の 1ch を返す
/// (曲がり補正の検出用。RGB を作ってから変換する手間を省く)。
Uint8List warpPerspectiveGray({
  required Uint8List src,
  required int srcW,
  required int srcH,
  required int numCh,
  required List<Offset> srcQuad,
  required int outW,
  required int outH,
}) =>
    _warp(src, srcW, srcH, numCh, srcQuad, outW, outH, null, gray: true);

/// 双一次補間の重みの固定小数点の桁 (2^11)。
const int _wBits = 11;
const int _wOne = 1 << _wBits;

/// 出力の各画素 (x + 0.5, y + 0.5) を逆写像でソースへ戻し、双一次補間で取る。
///
/// 実機で 1 枚数百 ms かかる工程なので、画素ごとの Offset の生成と関数呼び出しを避け、
/// 行の中では射影の分子・分母を足し算で進める (曲がり補正があるときは y が画素ごとに
/// 変わるので直接計算する)。補間は整数の重み (2^-11 刻み) で行う。
Uint8List _warp(Uint8List src, int srcW, int srcH, int numCh, List<Offset> srcQuad,
    int outW, int outH, PageDewarp? dewarp,
    {required bool gray}) {
  final dstQuad = <Offset>[
    Offset.zero,
    Offset(outW.toDouble(), 0),
    Offset(outW.toDouble(), outH.toDouble()),
    Offset(0, outH.toDouble()),
  ];
  // 出力 -> ソース の逆写像
  final m = Homography.fromPoints(dstQuad, srcQuad).m;
  final m0 = m[0], m1 = m[1], m2 = m[2];
  final m3 = m[3], m4 = m[4], m5 = m[5];
  final m6 = m[6], m7 = m[7], m8 = m[8];
  final outCh = gray ? 1 : 3;
  final out = Uint8List(outW * outH * outCh);
  final maxX = srcW - 1, maxY = srcH - 1;
  final srcWd = srcW.toDouble(), srcHd = srcH.toDouble();
  const half = 1 << (2 * _wBits - 1);
  for (int y = 0; y < outH; y++) {
    final cy = y + 0.5;
    // dewarp なしのときの行頭 (x = 0.5) の分子・分母と、x が 1 進むごとの増分
    var nx = m0 * 0.5 + m1 * cy + m2;
    var ny = m3 * 0.5 + m4 * cy + m5;
    var nw = m6 * 0.5 + m7 * cy + m8;
    var oi = y * outW * outCh;
    for (int x = 0; x < outW; x++, oi += outCh) {
      double px, py, pw;
      if (dewarp == null) {
        px = nx;
        py = ny;
        pw = nw;
        nx += m0;
        ny += m3;
        nw += m6;
      } else {
        final cx = x + 0.5;
        final yy = dewarp.sourceY(cx / outW, cy / outH) * outH;
        px = m0 * cx + m1 * yy + m2;
        py = m3 * cx + m4 * yy + m5;
        pw = m6 * cx + m7 * yy + m8;
      }
      final sx = px / pw - 0.5;
      final sy = py / pw - 0.5;
      if (!(sx >= -1 && sy >= -1 && sx <= srcWd && sy <= srcHd)) {
        // 範囲外 (NaN を含む) は白
        out[oi] = 255;
        if (!gray) {
          out[oi + 1] = 255;
          out[oi + 2] = 255;
        }
        continue;
      }
      final x0 = sx.floor();
      final y0 = sy.floor();
      final wx = ((sx - x0) * _wOne).toInt();
      final wy = ((sy - y0) * _wOne).toInt();
      final cx0 = x0 < 0 ? 0 : (x0 > maxX ? maxX : x0);
      final cy0 = y0 < 0 ? 0 : (y0 > maxY ? maxY : y0);
      final cx1 = x0 + 1 < 0 ? 0 : (x0 + 1 > maxX ? maxX : x0 + 1);
      final cy1 = y0 + 1 < 0 ? 0 : (y0 + 1 > maxY ? maxY : y0 + 1);
      final w00 = (_wOne - wx) * (_wOne - wy);
      final w10 = wx * (_wOne - wy);
      final w01 = (_wOne - wx) * wy;
      final w11 = wx * wy;
      final i00 = (cy0 * srcW + cx0) * numCh;
      final i10 = (cy0 * srcW + cx1) * numCh;
      final i01 = (cy1 * srcW + cx0) * numCh;
      final i11 = (cy1 * srcW + cx1) * numCh;
      final r = (src[i00] * w00 + src[i10] * w10 + src[i01] * w01 + src[i11] * w11 + half) >>
          (2 * _wBits);
      final g = (src[i00 + 1] * w00 +
              src[i10 + 1] * w10 +
              src[i01 + 1] * w01 +
              src[i11 + 1] * w11 +
              half) >>
          (2 * _wBits);
      final b = (src[i00 + 2] * w00 +
              src[i10 + 2] * w10 +
              src[i01 + 2] * w01 +
              src[i11 + 2] * w11 +
              half) >>
          (2 * _wBits);
      if (gray) {
        out[oi] = (299 * r + 587 * g + 114 * b + 500) ~/ 1000;
      } else {
        out[oi] = r;
        out[oi + 1] = g;
        out[oi + 2] = b;
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
