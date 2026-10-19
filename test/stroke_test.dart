import 'package:flutter_test/flutter_test.dart';

import 'package:futoji/models/stroke.dart';
import 'package:futoji/widgets/stroke_layer.dart';

void main() {
  Stroke line({
    double width = 0.006,
    List<Offset>? points,
  }) =>
      Stroke(
        color: 0xFFE53935,
        width: width,
        points: points ??
            const <Offset>[
              Offset(0.0, 0.0),
              Offset(0.1, 0.0),
              Offset(0.2, 0.0),
              Offset(0.3, 0.0),
              Offset(0.4, 0.0),
            ],
      );

  group('hitsNormalized (消しゴムの当たり判定)', () {
    test('線分に沿って擦ると当たる (端点以外でも)', () {
      final s = line();
      // (0.05, 0) - (0.15, 0) の間の線分上
      expect(StrokeLayerPainter.hitsNormalized(s, const Offset(0.15, 0.0), 0.01),
          isTrue);
      // 半径 0.01 以内の近傍
      expect(StrokeLayerPainter.hitsNormalized(s, const Offset(0.25, 0.009), 0.01),
          isTrue);
    });

    test('離れていると当たらない', () {
      final s = line();
      expect(StrokeLayerPainter.hitsNormalized(s, const Offset(0.2, 0.2), 0.01),
          isFalse);
      expect(StrokeLayerPainter.hitsNormalized(s, const Offset(0.9, 0.9), 0.05),
          isFalse);
    });

    test('1 点ストロークは点距離で判定', () {
      final s = line(points: const <Offset>[Offset(0.5, 0.5)]);
      expect(StrokeLayerPainter.hitsNormalized(s, const Offset(0.51, 0.5), 0.02),
          isTrue);
      expect(StrokeLayerPainter.hitsNormalized(s, const Offset(0.6, 0.5), 0.02),
          isFalse);
    });
  });

  group('splitStroke (部分消しゴム)', () {
    test('中央を消すと 2 本に分割され色・幅を引き継ぐ', () {
      final s = line();
      final out = StrokeLayerPainter.splitStroke(s, const Offset(0.2, 0.0), 0.011);
      expect(out.length, 2);
      // 前半 [0.0..0.1] と 後半 [0.3..0.4]
      expect(out[0].points.first, const Offset(0.0, 0.0));
      expect(out[0].points.last, const Offset(0.1, 0.0));
      expect(out[1].points.first, const Offset(0.3, 0.0));
      expect(out[1].points.last, const Offset(0.4, 0.0));
      for (final part in out) {
        expect(part.color, 0xFFE53935);
        expect(part.width, s.width);
      }
    });

    test('端を消すと 1 本になる', () {
      final s = line();
      final out = StrokeLayerPainter.splitStroke(s, const Offset(0.0, 0.0), 0.011);
      expect(out.length, 1);
      expect(out.first.points.first, const Offset(0.1, 0.0));
    });

    test('全部消すと空リスト', () {
      final s = line(points: const <Offset>[Offset(0.1, 0.1), Offset(0.12, 0.1)]);
      final out =
          StrokeLayerPainter.splitStroke(s, const Offset(0.11, 0.1), 0.02);
      expect(out, isEmpty);
    });

    test('触れていないストロークは元のまま 1 本で返る', () {
      final s = line();
      final out =
          StrokeLayerPainter.splitStroke(s, const Offset(0.9, 0.9), 0.01);
      expect(out.length, 1);
      expect(identical(out.first, s), isTrue);
    });

    test('点間隔の広い線分の途中を消すとその線分で切断される', () {
      // 点は 0.0 / 0.1 / 0.4 / 0.5。0.25 付近は線分 (0.1→0.4) 上のみ
      final s = line(points: const <Offset>[
        Offset(0.0, 0.0),
        Offset(0.1, 0.0),
        Offset(0.4, 0.0),
        Offset(0.5, 0.0),
      ]);
      final out =
          StrokeLayerPainter.splitStroke(s, const Offset(0.25, 0.0), 0.02);
      expect(out.length, 2);
      expect(out[0].points, const <Offset>[Offset(0.0, 0.0), Offset(0.1, 0.0)]);
      expect(out[1].points, const <Offset>[Offset(0.4, 0.0), Offset(0.5, 0.0)]);
    });

    test('1 点ストロークを触ると消える', () {
      final s = line(points: const <Offset>[Offset(0.5, 0.5)]);
      expect(
          StrokeLayerPainter.splitStroke(s, const Offset(0.5, 0.5), 0.02),
          isEmpty);
      expect(
          StrokeLayerPainter.splitStroke(s, const Offset(0.8, 0.8), 0.02).length,
          1);
    });
  });

  group('rotated90 (ページの回転)', () {
    void expectNear(Offset a, Offset b) {
      expect(a.dx, closeTo(b.dx, 1e-9));
      expect(a.dy, closeTo(b.dy, 1e-9));
    }

    test('右に回すと左上は右上へ、右上は右下へ移る', () {
      final s = line(points: const <Offset>[Offset(0, 0), Offset(1, 0), Offset(0.2, 0.7)])
          .rotated90(clockwise: true, pageAspect: 1);
      expectNear(s.points[0], const Offset(1, 0));
      expectNear(s.points[1], const Offset(1, 1));
      expectNear(s.points[2], const Offset(0.3, 0.2));
    });

    test('左に回すと右回りの逆になる', () {
      final s = line(points: const <Offset>[Offset(0.2, 0.7), Offset(0.9, 0.1)]);
      final back = s
          .rotated90(clockwise: true, pageAspect: 0.7)
          .rotated90(clockwise: false, pageAspect: 1 / 0.7);
      for (int i = 0; i < s.points.length; i++) {
        expectNear(back.points[i], s.points[i]);
      }
      expect(back.width, closeTo(s.width, 1e-12));
      expect(back.color, s.color);
    });

    test('線の太さ (px) は変わらない', () {
      // 幅 1000 x 高さ 1414 のページ。回すと幅は 1414 になる
      final s = line(width: 0.007).rotated90(clockwise: true, pageAspect: 1000 / 1414);
      expect(s.width * 1414, closeTo(0.007 * 1000, 1e-9));
    });
  });

  group('snapshotStrokes (undo 用スナップショット)', () {
    test('独立したコピーを作る (要素・点列とも)', () {
      final original = <Stroke>[
        line(points: <Offset>[
          Offset(0.0, 0.0),
          Offset(0.1, 0.0),
          Offset(0.2, 0.0),
        ]),
        line(points: <Offset>[Offset(0.1, 0.1)]),
      ];
      final snap = snapshotStrokes(original);
      expect(snap.length, original.length);
      expect(identical(snap.first, original.first), isFalse);
      expect(identical(snap.first.points, original.first.points), isFalse);
      // 内容は一致
      expect(snap.first.points.first, original.first.points.first);
      // 元を書き換えても影響しない
      original.first.points.add(const Offset(9, 9));
      expect(snap.first.points.contains(const Offset(9, 9)), isFalse);
    });
  });
}
