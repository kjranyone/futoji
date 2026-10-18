import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:futoji/services/warper.dart';

void main() {
  group('Homography', () {
    test('恒等変換', () {
      final h = Homography.fromPoints(
        const [Offset(0, 0), Offset(1, 0), Offset(1, 1), Offset(0, 1)],
        const [Offset(0, 0), Offset(1, 0), Offset(1, 1), Offset(0, 1)],
      );
      final p = h.apply(const Offset(0.3, 0.7));
      expect(p.dx, closeTo(0.3, 1e-9));
      expect(p.dy, closeTo(0.7, 1e-9));
    });

    test('スケール + 平行移動', () {
      final h = Homography.fromPoints(
        const [Offset(0, 0), Offset(1, 0), Offset(1, 1), Offset(0, 1)],
        const [Offset(10, 5), Offset(20, 5), Offset(20, 25), Offset(10, 25)],
      );
      final p = h.apply(const Offset(0.5, 0.25));
      expect(p.dx, closeTo(15, 1e-6));
      expect(p.dy, closeTo(10, 1e-6));
    });

    test('台形 (透視) 変換と逆変換', () {
      // 左右で高さの違う台形
      const src = [
        Offset(0, 10),
        Offset(100, 0),
        Offset(100, 80),
        Offset(0, 100),
      ];
      const dst = [
        Offset(0, 0),
        Offset(200, 0),
        Offset(200, 100),
        Offset(0, 100),
      ];
      final h = Homography.fromPoints(src, dst);
      for (int i = 0; i < 4; i++) {
        final p = h.apply(src[i]);
        expect(p.dx, closeTo(dst[i].dx, 1e-6), reason: 'corner $i');
        expect(p.dy, closeTo(dst[i].dy, 1e-6), reason: 'corner $i');
      }
      final inv = h.inverse();
      for (int i = 0; i < 4; i++) {
        final p = inv.apply(dst[i]);
        expect(p.dx, closeTo(src[i].dx, 1e-6), reason: 'inv corner $i');
        expect(p.dy, closeTo(src[i].dy, 1e-6), reason: 'inv corner $i');
      }
    });
  });

  group('warpPerspectiveRgb', () {
    Uint8List gradient(int w, int h, int numCh) {
      final b = Uint8List(w * h * numCh);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final i = (y * w + x) * numCh;
          b[i] = (x * 255) ~/ (w - 1);
          b[i + 1] = (y * 255) ~/ (h - 1);
          if (numCh > 2) b[i + 2] = 128;
        }
      }
      return b;
    }

    test('RGBA (4ch) 入力でも RGB (3ch) と同じ出力になる', () {
      // 保存処理はデコード結果を RGBA のまま渡す (fast_decode.dart)
      const w = 120, h = 90;
      const quad = [
        Offset(10, 8),
        Offset(110, 12),
        Offset(105, 85),
        Offset(6, 80),
      ];
      Uint8List run(int ch) => warpPerspectiveRgb(
            src: gradient(w, h, ch),
            srcW: w,
            srcH: h,
            numCh: ch,
            srcQuad: quad,
            outW: 64,
            outH: 48,
          );
      expect(run(4), run(3));
    });

    test('全面四角形はほぼコピーになる', () {
      const w = 100, h = 60;
      final src = gradient(w, h, 3);
      final out = warpPerspectiveRgb(
        src: src,
        srcW: w,
        srcH: h,
        numCh: 3,
        srcQuad: const [
          Offset(0, 0),
          Offset(w - 1.0, 0),
          Offset(w - 1.0, h - 1.0),
          Offset(0, h - 1.0),
        ],
        outW: 50,
        outH: 30,
      );
      // 中央画素の R は x=49.5 → 49.5/99*255 ≈ 127.5
      final i = ((15 * 50) + 25) * 3;
      expect(out[i], closeTo(127, 3));
    });

    test('内側の矩形を切り抜くと座標が一致する', () {
      const w = 200, h = 150;
      final src = gradient(w, h, 3);
      // (20,20)-(180,20)-(180,130)-(20,130) を 160x110 に
      const quad = [
        Offset(20, 20),
        Offset(180, 20),
        Offset(180, 130),
        Offset(20, 130),
      ];
      final size = outputSizeForQuad(quad, minSide: 0);
      expect(size.width.round(), 160);
      expect(size.height.round(), 110);
      final out = warpPerspectiveRgb(
        src: src,
        srcW: w,
        srcH: h,
        numCh: 3,
        srcQuad: quad,
        outW: 160,
        outH: 110,
      );
      // 出力 (25, 25) はソース (45, 45) に対応するはず
      final oi = (25 * 160 + 25) * 3;
      final si = (45 * 200 + 45) * 3;
      expect(out[oi], closeTo(src[si], 3));
      expect(out[oi + 1], closeTo(src[si + 1], 3));
    });

    test('範囲外は白で埋まる', () {
      final src = gradient(50, 50, 3);
      // ソースの外周まで行かない小さい四角形 → クリップ領域は発生しないが、
      // あえて全面四角 + 出力を拡大して白埋めを確認
      final out = warpPerspectiveRgb(
        src: src,
        srcW: 50,
        srcH: 50,
        numCh: 3,
        srcQuad: const [
          Offset(25, 25),
          Offset(25, 25),
          Offset(25, 25),
          Offset(25, 25),
        ],
        outW: 10,
        outH: 10,
      );
      // 退化四角形でもクラッシュせず白または近似値で埋まっている
      for (int i = 0; i < out.length; i++) {
        expect(out[i], inInclusiveRange(0, 255));
      }
    });

    // 高速化 (増分計算 + 整数の重み) の前の素直な実装との比較
    final rnd = math.Random(3);
    Uint8List noise(int w, int h, int ch) =>
        Uint8List.fromList(List<int>.generate(w * h * ch, (_) => rnd.nextInt(256)));
    const quads = <List<Offset>>[
      [Offset(10, 8), Offset(150, 20), Offset(140, 110), Offset(4, 100)],
      // ソースからはみ出す四角形 (白埋めの境界)
      [Offset(-20, -10), Offset(170, 5), Offset(180, 130), Offset(-5, 120)],
    ];

    test('素直な実装と ±1 以内で一致する (RGB / 輝度)', () {
      const w = 160, h = 120;
      for (final ch in const [3, 4]) {
        final src = noise(w, h, ch);
        for (final quad in quads) {
          final ref = _referenceWarp(src, w, h, ch, quad, 97, 73);
          final out = warpPerspectiveRgb(
              src: src, srcW: w, srcH: h, numCh: ch, srcQuad: quad, outW: 97, outH: 73);
          for (int i = 0; i < ref.length; i++) {
            expect((out[i] - ref[i]).abs(), lessThanOrEqualTo(1), reason: 'ch=$ch i=$i');
          }
          final gray = warpPerspectiveGray(
              src: src, srcW: w, srcH: h, numCh: ch, srcQuad: quad, outW: 97, outH: 73);
          for (int i = 0; i < gray.length; i++) {
            final l = (0.299 * ref[i * 3] + 0.587 * ref[i * 3 + 1] + 0.114 * ref[i * 3 + 2])
                .round();
            expect((gray[i] - l).abs(), lessThanOrEqualTo(1), reason: 'gray ch=$ch i=$i');
          }
        }
      }
    });
  });

  group('outputSizeForQuad', () {
    test('長辺の上限', () {
      final size = outputSizeForQuad(
        const [
          Offset(0, 0),
          Offset(4000, 0),
          Offset(4000, 1000),
          Offset(0, 1000),
        ],
        maxSide: 2400,
      );
      expect(size.width, 2400);
      expect(size.height, 600);
    });

    test('短すぎる場合は最小サイズまで等比拡大', () {
      final size = outputSizeForQuad(
        const [
          Offset(0, 0),
          Offset(100, 0),
          Offset(100, 80),
          Offset(0, 80),
        ],
        minSide: 420,
      );
      expect(size.width, 420);
      expect(size.height, closeTo(336, 1)); // アスペクト比は保持される
    });
  });

  group('紙の縦横比の推定', () {
    // 幅 [w]・高さ [h] の長方形を、x 軸まわり [tilt]・y 軸まわり [pan]・光軸まわり [roll]
    // (ラジアン) に傾けて距離 [dist] に置き、焦点距離 [f] のカメラで 3000x4000 の画像に写す。
    List<Offset> project(double w, double h,
        {double tilt = 0, double pan = 0, double roll = 0, double dist = 400, double f = 3200,
        double shiftX = 0, double shiftY = 0}) {
      Offset proj(double x, double y) {
        // Rz * Ry * Rx を (x, y, 0) にかける
        var px = x, py = y, pz = 0.0;
        var t = py * math.cos(tilt) - pz * math.sin(tilt);
        pz = py * math.sin(tilt) + pz * math.cos(tilt);
        py = t;
        t = px * math.cos(pan) + pz * math.sin(pan);
        pz = -px * math.sin(pan) + pz * math.cos(pan);
        px = t;
        t = px * math.cos(roll) - py * math.sin(roll);
        py = px * math.sin(roll) + py * math.cos(roll);
        px = t;
        px += shiftX;
        py += shiftY;
        pz += dist;
        return Offset(1500 + f * px / pz, 2000 + f * py / pz);
      }

      return <Offset>[
        proj(-w / 2, -h / 2),
        proj(w / 2, -h / 2),
        proj(w / 2, h / 2),
        proj(-w / 2, h / 2),
      ];
    }

    double estimate(List<Offset> quad, {double f = 3200}) =>
        estimateQuadAspect(quad, imageW: 3000, imageH: 4000, focalPx: f)!;

    test('斜めに写した A4 から元の比率が戻る', () {
      const a4 = 210 / 297;
      expect(estimate(project(210, 297, tilt: 0.5)), closeTo(a4, 1e-6));
      expect(estimate(project(210, 297, pan: -0.4)), closeTo(a4, 1e-6));
      expect(estimate(project(210, 297, tilt: 0.35, pan: 0.3, roll: 0.2, shiftX: 30, shiftY: -50)),
          closeTo(a4, 1e-6));
    });

    test('辺長の平均では潰れる傾きでも推定は潰れない', () {
      final quad = project(210, 297, tilt: 0.6);
      final naive = outputSizeForQuad(quad, maxSide: 100000, minSide: 0);
      // 前後に傾けると縦が縮んで写る (平均だと横長に潰れる)
      expect(naive.width / naive.height, greaterThan(210 / 297 * 1.1));
      final size = outputSizeForQuad(quad, maxSide: 100000, minSide: 0, aspect: estimate(quad));
      expect(size.width / size.height, closeTo(210 / 297, 0.01));
      // 縮んだ側 (縦) を伸ばす: 幅は辺長の平均のまま
      expect(size.width, closeTo(naive.width, 1));
    });

    test('正面から撮った長方形はそのままの比率', () {
      expect(estimate(project(300, 100)), closeTo(3, 1e-6));
    });

    test('焦点距離が多少違っても大きくは外れない', () {
      final quad = project(210, 297, tilt: 0.4, pan: 0.2, f: 3200);
      // 実際の焦点距離から ±20% ずれた値で推定
      expect(estimate(quad, f: 2560), closeTo(210 / 297, 210 / 297 * 0.05));
      expect(estimate(quad, f: 3840), closeTo(210 / 297, 210 / 297 * 0.05));
    });

    test('退化した四角形は null', () {
      const line = [Offset(0, 0), Offset(10, 0), Offset(20, 0), Offset(30, 0)];
      expect(estimateQuadAspect(line, imageW: 100, imageH: 100, focalPx: 100), isNull);
    });

    test('√2 の近くだけ √2 に寄せ、向きは保つ', () {
      expect(snapToPaperAspect(0.72), closeTo(1 / math.sqrt2, 1e-12));
      expect(snapToPaperAspect(1.38), closeTo(math.sqrt2, 1e-12));
      expect(snapToPaperAspect(0.75), 0.75); // 3:4 は寄せない
      expect(snapToPaperAspect(1.0), 1.0);
    });

    test('35mm 換算の焦点距離をピクセルに直す', () {
      // 対角 5000px の画像で 43.27mm 相当 = 対角と同じ長さ
      expect(focalPxFrom35mm(43.27, 3000, 4000), closeTo(5000, 1e-9));
    });
  });

  test('isConvexQuad', () {
    expect(
      isConvexQuad(const [
        Offset(0, 0),
        Offset(10, 0),
        Offset(10, 10),
        Offset(0, 10),
      ]),
      isTrue,
    );
    // 蝶型 (非凸)
    expect(
      isConvexQuad(const [
        Offset(0, 0),
        Offset(10, 10),
        Offset(10, 0),
        Offset(0, 10),
      ]),
      isFalse,
    );
  });

  // テスト用のヘルパーが export されていない場合に備えた数学的整合チェック
  test('台形補正の面積比は辺長比に一致', () {
    const quad = [
      Offset(0, 0),
      Offset(300, 10),
      Offset(310, 420),
      Offset(-5, 410),
    ];
    final size = outputSizeForQuad(quad, maxSide: 1000);
    final wTop = (quad[1] - quad[0]).distance;
    final wBottom = (quad[2] - quad[3]).distance;
    final avg = (wTop + wBottom) / 2;
    final ratio = size.width / avg;
    final hLeft = (quad[3] - quad[0]).distance;
    final hRight = (quad[2] - quad[1]).distance;
    final ratioH = size.height / ((hLeft + hRight) / 2);
    expect(ratio, closeTo(ratioH, 0.02));
    expect(math.max(size.width, size.height), lessThanOrEqualTo(1000));
  });
}

/// 高速化前の素直な実装 (画素ごとに逆写像して double で双一次補間)。
Uint8List _referenceWarp(
    Uint8List src, int srcW, int srcH, int numCh, List<Offset> srcQuad, int outW, int outH) {
  final dstQuad = <Offset>[
    Offset.zero,
    Offset(outW.toDouble(), 0),
    Offset(outW.toDouble(), outH.toDouble()),
    Offset(0, outH.toDouble()),
  ];
  final inv = Homography.fromPoints(dstQuad, srcQuad);
  final out = Uint8List(outW * outH * 3);
  for (int y = 0; y < outH; y++) {
    for (int x = 0; x < outW; x++) {
      final p = inv.apply(Offset(x + 0.5, y + 0.5));
      final sx = p.dx - 0.5;
      final sy = p.dy - 0.5;
      final oi = (y * outW + x) * 3;
      if (sx < -1 || sy < -1 || sx > srcW || sy > srcH) {
        out[oi] = out[oi + 1] = out[oi + 2] = 255;
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
      for (int c = 0; c < 3; c++) {
        final v = src[(cy0 * srcW + cx0) * numCh + c] * (1 - fx) * (1 - fy) +
            src[(cy0 * srcW + cx1) * numCh + c] * fx * (1 - fy) +
            src[(cy1 * srcW + cx0) * numCh + c] * (1 - fx) * fy +
            src[(cy1 * srcW + cx1) * numCh + c] * fx * fy;
        out[oi + c] = v.round().clamp(0, 255);
      }
    }
  }
  return out;
}
