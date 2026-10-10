import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:futoji/services/detection_worker.dart';

/// 暗い背景に明るい矩形 (紙) を置いた輝度画像。
Uint8List paperGray(int w, int h) {
  final g = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final inside = x > w * 0.2 && x < w * 0.8 && y > h * 0.2 && y < h * 0.8;
      g[y * w + x] = inside ? 230 : 40;
    }
  }
  return g;
}

Future<List<Offset>?> detectOnce(DetectionWorker worker, Uint8List g, int w, int h) {
  final c = Completer<List<Offset>?>();
  expect(worker.submit(g, w, h, c.complete), isTrue,
      reason: '前の結果を受け取った後は次の依頼を受け付けること');
  return c.future.timeout(const Duration(seconds: 20));
}

void main() {
  // PC ではモデル (libonnxruntime.so) を読めないため、ワーカーは
  // ヒューリスティック経路になる。ここで検証したいのは isolate との
  // 往復と busy 状態の管理 (推論の中身は評価ハーネスで検証する)。
  test('結果を受け取るたびに busy が解除され、連続して検出できる', () async {
    final worker = DetectionWorker();
    await worker.start(Uint8List(16)); // 不正なモデル → ヒューリスティック
    const w = 320, h = 240;
    final g = paperGray(w, h);
    try {
      for (int i = 0; i < 3; i++) {
        final quad = await detectOnce(worker, g, w, h);
        expect(quad, isNotNull, reason: '$i 回目');
        expect(worker.isBusy, isFalse);
      }
    } finally {
      worker.dispose();
    }
  });

  test('処理中の依頼は受け付けない (フレームを捨てる)', () async {
    final worker = DetectionWorker();
    await worker.start(Uint8List(16));
    const w = 320, h = 240;
    final g = paperGray(w, h);
    try {
      final c = Completer<List<Offset>?>();
      expect(worker.submit(g, w, h, c.complete), isTrue);
      expect(worker.submit(g, w, h, (_) {}), isFalse);
      await c.future.timeout(const Duration(seconds: 20));
      expect(worker.isBusy, isFalse);
    } finally {
      worker.dispose();
    }
  });
}
