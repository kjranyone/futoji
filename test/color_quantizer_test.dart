import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:futoji/services/color_quantizer.dart';

Uint8List rgbImage(int w, int h, Uint8List Function(int x, int y) pixel) {
  final out = Uint8List(w * h * 3);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final c = pixel(x, y);
      out[(y * w + x) * 3] = c[0];
      out[(y * w + x) * 3 + 1] = c[1];
      out[(y * w + x) * 3 + 2] = c[2];
    }
  }
  return out;
}

int distinctColors(Uint8List rgb) {
  final seen = <String>{};
  for (int i = 0; i + 2 < rgb.length; i += 3) {
    seen.add('${rgb[i]},${rgb[i + 1]},${rgb[i + 2]}');
  }
  return seen.length;
}

void main() {
  group('decidePaletteSize (色域の自動判定)', () {
    test('白黒の楽譜的な画像は 8 色になる', () {
      // 白紙 + 黒文字 (無彩色) + わずかな赤ペン (数%)
      final imgBytes = rgbImage(200, 200, (x, y) {
        if ((x * 7 + y * 13) % 97 < 3) return Uint8List.fromList([200, 30, 30]);
        if ((x + y) % 2 == 0) return Uint8List.fromList([255, 255, 255]);
        return Uint8List.fromList([30, 30, 30]);
      });
      expect(ColorQuantizer.decidePaletteSize(imgBytes), 8,
          reason: '無彩色寄りは 8 色');
    });

    test('ユニーク色が少ないカラフル画像はその色数を返す (劣化なし)', () {
      final imgBytes = rgbImage(40, 40, (x, y) {
        if (x < 20) return Uint8List.fromList([255, 0, 0]);
        return Uint8List.fromList([0, 0, 255]);
      });
      expect(ColorQuantizer.decidePaletteSize(imgBytes), 2);
    });

    test('カラフルな画像は 32 色になる', () {
      final imgBytes = rgbImage(120, 120, (x, y) {
        return Uint8List.fromList([
          (x * 5) % 256,
          (y * 5) % 256,
          ((x + y) * 3) % 256,
        ]);
      });
      expect(ColorQuantizer.decidePaletteSize(imgBytes),
          ColorQuantizer.maxAutoColors);
    });

    test('グレーのグラデーションは 8 色になる', () {
      final imgBytes = rgbImage(200, 200, (x, y) {
        final v = (x * 255 ~/ 200);
        return Uint8List.fromList([v, v, v]);
      });
      expect(ColorQuantizer.decidePaletteSize(imgBytes), 8);
    });
  });

  group('quantize (メディアンカット減色)', () {
    test('2 色画像は完全に保持される', () {
      final imgBytes = rgbImage(64, 64, (x, y) {
        if (x < 32) return Uint8List.fromList([10, 20, 30]);
        return Uint8List.fromList([240, 230, 220]);
      });
      ColorQuantizer.quantize(imgBytes, 16);
      expect(distinctColors(imgBytes), 2);
      expect(imgBytes[0], 10);
      expect(imgBytes[32 * 3], 240);
    });

    test('減色後の色数は maxColors 以下になる', () {
      final imgBytes = rgbImage(120, 120, (x, y) {
        return Uint8List.fromList([
          (x * 5) % 256,
          (y * 5) % 256,
          ((x + y) * 3) % 256,
        ]);
      });
      ColorQuantizer.quantize(imgBytes, 8);
      expect(distinctColors(imgBytes), lessThanOrEqualTo(8));
    });

    test('近似色は 1 色にまとまる', () {
      // 240〜255 のわずかに違う赤
      final imgBytes = rgbImage(60, 60, (x, y) {
        return Uint8List.fromList([240 + ((x + y) % 16), 10, 10]);
      });
      ColorQuantizer.quantize(imgBytes, 4);
      expect(distinctColors(imgBytes), lessThanOrEqualTo(4));
    });

    test('元の色数が十分少ない場合は変化しない', () {
      final imgBytes = rgbImage(32, 32, (x, y) {
        if (x < 16) return Uint8List.fromList([0, 0, 0]);
        return Uint8List.fromList([255, 255, 255]);
      });
      final before = Uint8List.fromList(imgBytes);
      ColorQuantizer.quantize(imgBytes, 8);
      expect(imgBytes, before);
    });
  });

  group('quantize (大画像の間引きサンプリング)', () {
    test('サンプリングされなかった色も最近傍のパレット色へ置換される', () {
      // 2M 画素超 → 4px ごとのサンプリングになる。
      // x % 4 == 1 の列だけ薄いピンクにすると、その色は集計されない。
      const w = 2048, h = 1040;
      final imgBytes = rgbImage(w, h, (x, y) {
        if (x % 4 == 1) return Uint8List.fromList([250, 200, 200]);
        return (x ~/ 4).isEven
            ? Uint8List.fromList([255, 255, 255])
            : Uint8List.fromList([0, 0, 0]);
      });
      ColorQuantizer.quantize(imgBytes, 2);
      // 薄いピンクは白に近いので白へ置換される
      // (パレット先頭の黒で塗られてはいけない)
      final i = 1 * 3;
      expect(<int>[imgBytes[i], imgBytes[i + 1], imgBytes[i + 2]],
          const <int>[255, 255, 255]);
    });
  });

  group('減色による軽量化', () {
    test('ノイズ画像の JPEG サイズが減色で小さくなる', () {
      // ランダムノイズ (フルカラー) を減色すると圧縮効率が上がる
      final noisy = rgbImage(160, 160, (x, y) {
        return Uint8List.fromList([
          (x * 31 + y * 17) % 256,
          (x * 13 + y * 41) % 256,
          (x * 7 + y * 53) % 256,
        ]);
      });
      final original = Uint8List.fromList(noisy);
      final before = img.encodeJpg(
          img.Image.fromBytes(
              width: 160, height: 160, bytes: original.buffer, numChannels: 3),
          quality: 90);

      ColorQuantizer.quantize(noisy, 16);
      final after = img.encodeJpg(
          img.Image.fromBytes(
              width: 160, height: 160, bytes: noisy.buffer, numChannels: 3),
          quality: 90);

      expect(after.length, lessThan(before.length),
          reason: '減色後 (${after.length}B) は元 (${before.length}B) より小さい');
      expect(distinctColors(noisy), lessThanOrEqualTo(16));
    });
  });
}
