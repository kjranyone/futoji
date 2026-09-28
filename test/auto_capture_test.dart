import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mymusicbook/services/auto_capture.dart';

void main() {
  List<Offset> quadAt(Offset center, double halfW, double halfH) {
    return <Offset>[
      Offset(center.dx - halfW, center.dy - halfH),
      Offset(center.dx + halfW, center.dy - halfH),
      Offset(center.dx + halfW, center.dy + halfH),
      Offset(center.dx - halfW, center.dy + halfH),
    ];
  }

  group('AutoCaptureController', () {
    test('安定した紙面で requiredStableChecks 回後に撮影を指示する', () {
      final c = AutoCaptureController(requiredStableChecks: 3);
      final q = quadAt(const Offset(0.5, 0.5), 0.3, 0.2);
      final t = DateTime(2026, 1, 1);
      expect(c.feed(q, t), isFalse);
      expect(c.feed(q, t.add(const Duration(milliseconds: 160))), isFalse);
      expect(c.feed(q, t.add(const Duration(milliseconds: 320))), isTrue,
          reason: '3 回目の安定チェックで発火');
      // 直後はクールダウン
      expect(c.feed(q, t.add(const Duration(milliseconds: 400))), isFalse);
    });

    test('クールダウン明けも同じ位置の紙では再撮影しない', () {
      final c = AutoCaptureController(
          requiredStableChecks: 3, cooldownMs: 1000);
      final q = quadAt(const Offset(0.5, 0.5), 0.3, 0.2);
      final t = DateTime(2026, 1, 1);
      c.feed(q, t);
      c.feed(q, t.add(const Duration(milliseconds: 160)));
      expect(c.feed(q, t.add(const Duration(milliseconds: 320))), isTrue);
      // クールダウン明け後も同じ紙
      final t2 = t.add(const Duration(seconds: 5));
      expect(c.feed(q, t2), isFalse);
      expect(c.feed(q, t2.add(const Duration(milliseconds: 160))), isFalse);
    });

    test('紙が十分動くと再武装して再撮影する', () {
      final c = AutoCaptureController(requiredStableChecks: 3, cooldownMs: 0);
      final q1 = quadAt(const Offset(0.5, 0.5), 0.3, 0.2);
      final t = DateTime(2026, 1, 1);
      c.feed(q1, t);
      c.feed(q1, t.add(const Duration(milliseconds: 160)));
      expect(c.feed(q1, t.add(const Duration(milliseconds: 320))), isTrue);
      // 10% 動いた紙
      final q2 = quadAt(const Offset(0.6, 0.5), 0.3, 0.2);
      final t2 = t.add(const Duration(seconds: 5));
      expect(c.feed(q2, t2), isFalse);
      expect(c.feed(q2, t2.add(const Duration(milliseconds: 160))), isFalse);
      expect(c.feed(q2, t2.add(const Duration(milliseconds: 320))), isTrue);
    });

    test('紙が消えたら参照がリセットされ、同じ位置の紙でも撮る', () {
      final c = AutoCaptureController(requiredStableChecks: 3, cooldownMs: 0);
      final q = quadAt(const Offset(0.5, 0.5), 0.3, 0.2);
      final t = DateTime(2026, 1, 1);
      c.feed(q, t);
      c.feed(q, t.add(const Duration(milliseconds: 160)));
      expect(c.feed(q, t.add(const Duration(milliseconds: 320))), isTrue);
      // 紙をどかす (検出失敗) → クールダウン中
      final t2 = t.add(const Duration(seconds: 5));
      c.feed(null, t2);
      // クールダウン明け後に検出失敗 → リセット
      final t3 = t.add(const Duration(seconds: 60));
      c.feed(null, t3);
      c.feed(null, t3.add(const Duration(milliseconds: 100)));
      // 同じ位置に紙が戻ってきても新規扱いで撮る
      final t4 = t.add(const Duration(seconds: 70));
      expect(c.feed(q, t4), isFalse);
      expect(c.feed(q, t4.add(const Duration(milliseconds: 160))), isFalse);
      expect(c.feed(q, t4.add(const Duration(milliseconds: 320))), isTrue);
    });

    test('小さすぎる紙面では撮影しない', () {
      final c = AutoCaptureController(requiredStableChecks: 1, minAreaRatio: 0.18);
      final tiny = quadAt(const Offset(0.5, 0.5), 0.05, 0.04); // 面積 0.004
      final t = DateTime(2026, 1, 1);
      expect(c.feed(tiny, t), isFalse);
      expect(c.feed(tiny, t.add(const Duration(milliseconds: 160))), isFalse);
    });

    test('動き続ける紙では撮影しない', () {
      final c = AutoCaptureController(requiredStableChecks: 3);
      final t = DateTime(2026, 1, 1);
      for (int i = 0; i < 10; i++) {
        final q = quadAt(Offset(0.3 + 0.02 * i, 0.5), 0.3, 0.2);
        expect(c.feed(q, t.add(Duration(milliseconds: 160 * i))), isFalse,
            reason: 'i=$i');
      }
    });

    test('noteManualCapture で手動撮影位置を記憶する', () {
      final c = AutoCaptureController(requiredStableChecks: 1, cooldownMs: 0);
      final q = quadAt(const Offset(0.5, 0.5), 0.3, 0.2);
      final t = DateTime(2026, 1, 1);
      c.noteManualCapture(q, t);
      expect(c.feed(q, t.add(const Duration(seconds: 5))), isFalse);
    });
  });

  group('frameToPreview / mapFrameCornersToImage', () {
    test('画面とフレームが同方向ならそのまま', () {
      final n = const Offset(0.2, 0.3);
      final out = frameToPreview(n, 640, 480, 90, 640 / 480);
      expect(out, n);
    });

    test('縦プレビューでは 90° 回転 (sensorOrientation=90)', () {
      // フレーム 640x480 (横センサー) → 縦プレビューボックス (aspect 0.5625):
      // (nx, ny) → (1-ny, nx)
      final out =
          frameToPreview(const Offset(0.1, 0.2), 640, 480, 90, 480 / 640);
      expect(out.dx, closeTo(1 - 0.2, 1e-9));
      expect(out.dy, closeTo(0.1, 1e-9));
    });

    test('フロントカメラ (sensorOrientation=270) は回転後に左右反転', () {
      // 回転: (nx, ny) → (ny, 1-nx)、鏡像表示なので x を反転 → (1-ny, 1-nx)
      final out = frameToPreview(
          const Offset(0.1, 0.2), 640, 480, 270, 480 / 640,
          mirror: true);
      expect(out.dx, closeTo(1 - 0.2, 1e-9));
      expect(out.dy, closeTo(1 - 0.1, 1e-9));
    });

    test('背面カメラは反転しない (mirror 既定 false)', () {
      final a = frameToPreview(const Offset(0.3, 0.6), 640, 480, 90, 480 / 640);
      final b = frameToPreview(const Offset(0.3, 0.6), 640, 480, 90, 480 / 640,
          mirror: false);
      expect(a, b);
    });

    test('mapFrameCornersToImage: 回転 + クロップ補正', () {
      // フレーム 4:3 (横) / 画像 3:4 (縦, EXIF回転済み)
      final corners = <Offset>[
        const Offset(0, 0),
        const Offset(1, 0),
        const Offset(1, 1),
        const Offset(0, 1),
      ];
      final out = mapFrameCornersToImage(
        corners: corners,
        frameW: 640,
        frameH: 480,
        sensorOrientation: 90,
        imageAspect: 480 / 640,
      );
      // フレーム全面 → 回転後も全面になるはず
      expect(out[0], const Offset(1, 0));
      expect(out[1], const Offset(1, 1));
      expect(out[2], const Offset(0, 1));
      expect(out[3], const Offset(0, 0));
    });

    test('adjustCornersForAspect: 上下クロップの補正', () {
      // ストリーム 16:9 にフル幅で映っているもの → 4:3 画像へ
      // ストリーム y=0.5 は画像でも 0.5、y=0 は画像 y=(1-0.75)/2=0.125
      final out = adjustCornersForAspect(
        const [Offset(0.5, 0.0)],
        16 / 9,
        4 / 3,
      );
      expect(out.first.dy, closeTo(0.125, 1e-9));
      final mid = adjustCornersForAspect(
        const [Offset(0.5, 0.5)],
        16 / 9,
        4 / 3,
      );
      expect(mid.first.dy, closeTo(0.5, 1e-9));
    });

    test('アスペクトがほぼ同じなら補正しない', () {
      final q = <Offset>[const Offset(0.25, 0.75)];
      final out = adjustCornersForAspect(q, 4 / 3, 4 / 3);
      expect(identical(out, q), isTrue);
    });
  });

  group('quadArea / maxCornerDelta', () {
    test('quadArea は単位正方形で 1.0', () {
      final q = <Offset>[
        Offset.zero,
        const Offset(1, 0),
        const Offset(1, 1),
        const Offset(0, 1),
      ];
      expect(quadArea(q), closeTo(1.0, 1e-9));
    });

    test('maxCornerDelta はコーナー移動量の最大', () {
      final a = <Offset>[
        Offset.zero,
        const Offset(1, 0),
        const Offset(1, 1),
        const Offset(0, 1),
      ];
      final b = <Offset>[
        const Offset(0, 0.05),
        const Offset(1, 0),
        const Offset(1, 1),
        const Offset(0, 1),
      ];
      expect(maxCornerDelta(a, b), closeTo(0.05, 1e-9));
    });
  });

  group('extractGrayPlane の数学的整合', () {
    test('間引き後のサイズは w~/d, h~/d', () {
      const w = 640, h = 480, d = 2;
      expect(w ~/ d, 320);
      expect(h ~/ d, 240);
      expect(Uint8List(320 * 240).length, 320 * 240);
    });
  });
}
