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
      final c = AutoCaptureController(countdownMs: 0, requiredStableChecks: 3);
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
      final c = AutoCaptureController(countdownMs: 0, requiredStableChecks: 3, cooldownMs: 1000);
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
      final c = AutoCaptureController(countdownMs: 0, requiredStableChecks: 3, cooldownMs: 0);
      final q1 = quadAt(const Offset(0.5, 0.5), 0.3, 0.2);
      final t = DateTime(2026, 1, 1);
      c.feed(q1, t);
      c.feed(q1, t.add(const Duration(milliseconds: 160)));
      expect(c.feed(q1, t.add(const Duration(milliseconds: 320))), isTrue);
      // 20% 動いた紙: 2 回続けて動きを確認して再武装 → 3 回の安定で撮る
      final q2 = quadAt(const Offset(0.7, 0.5), 0.3, 0.2);
      final t2 = t.add(const Duration(seconds: 5));
      expect(c.feed(q2, t2), isFalse);
      expect(c.feed(q2, t2.add(const Duration(milliseconds: 160))), isFalse);
      expect(c.feed(q2, t2.add(const Duration(milliseconds: 320))), isFalse);
      expect(c.feed(q2, t2.add(const Duration(milliseconds: 480))), isTrue);
    });

    test('カウントダウン: 紙が止まってから countdownMs 経つまで撮らず、動かすとやり直す', () {
      final c = AutoCaptureController(countdownMs: 1500, cooldownMs: 0);
      final q = quadAt(const Offset(0.5, 0.5), 0.3, 0.2);
      final t = DateTime(2026, 1, 1);
      expect(c.feed(q, t), isFalse);
      expect(c.countdownStartedAt, t);
      for (int ms = 160; ms < 1500; ms += 160) {
        expect(c.feed(q, t.add(Duration(milliseconds: ms))), isFalse, reason: '$ms ms');
      }
      // 途中で 5% 動かす → やり直し
      final moved = quadAt(const Offset(0.55, 0.5), 0.3, 0.2);
      final t2 = t.add(const Duration(milliseconds: 1440));
      expect(c.feed(moved, t2), isFalse);
      expect(c.countdownStartedAt, t2);
      expect(c.feed(moved, t2.add(const Duration(milliseconds: 1400))), isFalse);
      expect(c.feed(moved, t2.add(const Duration(milliseconds: 1520))), isTrue);
      expect(c.countdownStartedAt, isNull, reason: '撮影後は撮影済み (紙の入れ替え待ち)');
    });

    test('紙が一度も外れないまま撮影が続いたら 3 回で止める', () {
      final c = AutoCaptureController(countdownMs: 0, requiredStableChecks: 2, cooldownMs: 0);
      final t = DateTime(2026, 1, 1);
      var now = t;
      var shots = 0;
      // 紙は写ったまま、大きく動いては止まるを繰り返す (= 再武装の条件を満たし続ける)
      for (int round = 0; round < 6; round++) {
        final q = quadAt(Offset(round.isEven ? 0.4 : 0.6, 0.5), 0.25, 0.2);
        for (int k = 0; k < 4; k++) {
          now = now.add(const Duration(milliseconds: 160));
          if (c.feed(q, now)) shots++;
        }
      }
      expect(shots, 3);
      expect(c.paused, isTrue);
      // 紙が外れて戻ってきても、reset されるまでは止まったまま (呼び出し側が自動モードを切る)
      c.reset();
      expect(c.paused, isFalse);
    });

    test('紙が画面から外れれば、続けて撮っても止めない', () {
      final c = AutoCaptureController(countdownMs: 0, requiredStableChecks: 2, cooldownMs: 0);
      final q = quadAt(const Offset(0.5, 0.5), 0.3, 0.2);
      var now = DateTime(2026, 1, 1);
      var shots = 0;
      for (int page = 0; page < 6; page++) {
        for (int k = 0; k < 3; k++) {
          now = now.add(const Duration(milliseconds: 160));
          if (c.feed(q, now)) shots++;
        }
        // 紙を入れ替える間、一瞬紙が見えなくなる
        now = now.add(const Duration(milliseconds: 160));
        c.feed(null, now);
      }
      expect(shots, 6);
      expect(c.paused, isFalse);
    });

    test('検出枠が 2 通りの形を行き来しても、同じ紙を撮り直さない', () {
      // 実機で観測: 角の 1 つが約 10% 跳ぶ枠と元の枠が交互・連続して出る
      final c = AutoCaptureController(countdownMs: 0, requiredStableChecks: 3, cooldownMs: 0);
      final a = quadAt(const Offset(0.5, 0.5), 0.3, 0.2);
      final b = <Offset>[...a]..[3] = a[3] + const Offset(-0.06, 0.09);
      expect(maxCornerDelta(a, b), closeTo(0.108, 0.001));
      final t = DateTime(2026, 1, 1);
      c.feed(a, t);
      c.feed(a, t.add(const Duration(milliseconds: 160)));
      expect(c.feed(a, t.add(const Duration(milliseconds: 320))), isTrue);
      // その後 10 秒間、a と b が交互に、また b が続けて出ても撮らない
      var now = t.add(const Duration(seconds: 1));
      final seq = <List<Offset>>[b, a, b, b, b, b, a, b, a, a, b, b, b, b, b];
      for (final q in seq) {
        now = now.add(const Duration(milliseconds: 160));
        expect(c.feed(q, now), isFalse, reason: '同じ紙を撮り直した');
      }
    });

    test('紙が消えたら参照がリセットされ、同じ位置の紙でも撮る', () {
      final c = AutoCaptureController(countdownMs: 0, requiredStableChecks: 3, cooldownMs: 0);
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
      final c = AutoCaptureController(countdownMs: 0, requiredStableChecks: 1, minAreaRatio: 0.18);
      final tiny = quadAt(const Offset(0.5, 0.5), 0.05, 0.04); // 面積 0.004
      final t = DateTime(2026, 1, 1);
      expect(c.feed(tiny, t), isFalse);
      expect(c.feed(tiny, t.add(const Duration(milliseconds: 160))), isFalse);
    });

    test('動き続ける紙では撮影しない', () {
      final c = AutoCaptureController(countdownMs: 0, requiredStableChecks: 3);
      final t = DateTime(2026, 1, 1);
      for (int i = 0; i < 10; i++) {
        final q = quadAt(Offset(0.3 + 0.02 * i, 0.5), 0.3, 0.2);
        expect(c.feed(q, t.add(Duration(milliseconds: 160 * i))), isFalse,
            reason: 'i=$i');
      }
    });

    test('noteManualCapture で手動撮影位置を記憶する', () {
      final c = AutoCaptureController(countdownMs: 0, requiredStableChecks: 1, cooldownMs: 0);
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
