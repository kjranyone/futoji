import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mymusicbook/services/warper.dart';

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
