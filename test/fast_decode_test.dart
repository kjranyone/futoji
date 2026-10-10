import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:futoji/services/fast_decode.dart';

/// 向きが分かる非対称な絵 (生ピクセル 800x600: 左上に赤、右下寄りに白) に
/// EXIF orientation を付けた JPEG。image パッケージは EXIF を書き出さないため
/// PIL で作ったフィクスチャを使う (tools/.venv の Python で生成)。
Uint8List jpegWithOrientation(int orientation) =>
    File('test/fixtures/exif_orientation_$orientation.jpg').readAsBytesSync();

/// 既存経路 (純 Dart): デコード (decodeJpg が EXIF の向きを反映) → 長辺 cap に縮小。
img.Image reference(Uint8List bytes, int cap) {
  var im = img.bakeOrientation(img.decodeJpg(bytes)!);
  if (im.width >= im.height && im.width > cap) {
    im = img.copyResize(im, width: cap, interpolation: img.Interpolation.average);
  } else if (im.height > cap) {
    im = img.copyResize(im, height: cap, interpolation: img.Interpolation.average);
  }
  return im;
}

/// 2 画像を 64x64 の輝度に縮めたときの平均絶対差 (0..255)。
double meanAbsDiff(img.Image a, img.Image b) {
  final sa = img.grayscale(img.copyResize(a, width: 64, height: 64));
  final sb = img.grayscale(img.copyResize(b, width: 64, height: 64));
  double sum = 0;
  for (int y = 0; y < 64; y++) {
    for (int x = 0; x < 64; x++) {
      sum += (sa.getPixel(x, y).r - sb.getPixel(x, y).r).abs();
    }
  }
  return sum / (64 * 64);
}

void main() {
  for (final orientation in <int>[1, 3, 6, 8]) {
    testWidgets('EXIF orientation=$orientation: 既存経路と同じ向き・寸法・内容',
        (tester) async {
      const cap = 500; // 縮小も同時に検証する
      final bytes = jpegWithOrientation(orientation);
      final expected = reference(bytes, cap);
      // テスト自体の前提: EXIF が本当に書き込まれていること
      // (6/8 は 90 度回転なので、横長の生画像が縦長として扱われる)。
      // decodeJpg は向きを反映した後にタグを消すので、EXIF だけを読んで確かめる。
      expect(img.decodeJpgExif(bytes)!.imageIfd.orientation, orientation);
      if (orientation == 6 || orientation == 8) {
        expect(expected.height, greaterThan(expected.width));
      }
      final actual =
          (await tester.runAsync(() => decodeImageCapped(bytes, cap: cap)))!;
      expect(actual.width, expected.width, reason: '幅');
      expect(actual.height, expected.height, reason: '高さ');
      expect(actual.numChannels, 4); // RGBA のまま (詰め替えない)
      // 向きが違えば赤・白の位置がずれて差が大きくなる (同じなら JPEG 誤差程度)
      expect(meanAbsDiff(actual, expected), lessThan(6));
    });
  }

  testWidgets('cap より小さい画像は拡大しない', (tester) async {
    final bytes = jpegWithOrientation(1); // 800x600
    final actual =
        (await tester.runAsync(() => decodeImageCapped(bytes, cap: 1000)))!;
    expect(actual.width, 800);
    expect(actual.height, 600);
  });
}
