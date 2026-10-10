import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:futoji/services/raster.dart';

Uint8List _noise(int w, int h, int seed) {
  final rnd = math.Random(seed);
  return Uint8List.fromList(List<int>.generate(w * h * 3, (_) => rnd.nextInt(256)));
}

void main() {
  test('encodeBmp24 は image パッケージで読み戻すと元の画素になる', () {
    // 行の詰め物が要る幅 (w * 3 が 4 の倍数でない) と要らない幅の両方
    for (final (w, h) in const [(7, 5), (8, 3), (1, 1)]) {
      final rgb = _noise(w, h, w * 31 + h);
      final bmp = encodeBmp24(rgb, w, h);
      final back = img.decodeBmp(bmp)!;
      expect(back.width, w);
      expect(back.height, h);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final p = back.getPixel(x, y);
          final i = (y * w + x) * 3;
          expect([p.r, p.g, p.b], [rgb[i], rgb[i + 1], rgb[i + 2]], reason: '($x, $y) in ${w}x$h');
        }
      }
    }
  });

  test('downscaleRgbBox は対応する矩形の平均になる', () {
    const w = 103, h = 61;
    final rgb = _noise(w, h, 1);
    final (out, tw, th) = downscaleRgbBox(rgb, w, h, 20);
    expect(tw, 20);
    expect(th, (h * 20 / w).round());
    for (int j = 0; j < th; j++) {
      for (int i = 0; i < tw; i++) {
        final x0 = i * w ~/ tw, x1 = (i + 1) * w ~/ tw;
        final y0 = j * h ~/ th, y1 = (j + 1) * h ~/ th;
        for (int c = 0; c < 3; c++) {
          double s = 0;
          for (int y = y0; y < y1; y++) {
            for (int x = x0; x < x1; x++) {
              s += rgb[(y * w + x) * 3 + c];
            }
          }
          final avg = s / ((x1 - x0) * (y1 - y0));
          expect(out[(j * tw + i) * 3 + c], closeTo(avg, 0.5 + 1e-9));
        }
      }
    }
  });

  test('downscaleRgbBox は縦長でも長辺を合わせ、小さい画像はそのまま返す', () {
    final tall = _noise(50, 200, 2);
    final (_, tw, th) = downscaleRgbBox(tall, 50, 200, 40);
    expect(th, 40);
    expect(tw, 10);
    final small = _noise(30, 20, 3);
    final (same, sw, sh) = downscaleRgbBox(small, 30, 20, 420);
    expect(identical(same, small), isTrue);
    expect((sw, sh), (30, 20));
  });
}
