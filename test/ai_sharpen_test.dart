// AI シャープ化 (AiSharpen) を Windows 版 ORT で実際に動かして検証する。
// ORT ライブラリ (tools/ort/onnxruntime.dll) が無い環境ではスキップ。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mymusicbook/services/ai_sharpen.dart';

/// 楽譜もどき (横線 5 本と黒い玉・縦線)。タイル境界をまたぐ大きさにする。
img.Image sharpScore(int w, int h) {
  // 実写 (長辺 2600px) の楽譜に近い太さ: 五線 4px・間隔 30px・符頭の半径 14px
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(235, 232, 225));
  final black = img.ColorRgb8(30, 30, 30);
  for (int i = 0; i < 5; i++) {
    final y = 180 + i * 30;
    img.drawLine(im, x1: 20, y1: y, x2: w - 20, y2: y, color: black, thickness: 4);
  }
  for (int x = 100; x < w - 100; x += 120) {
    final y = 240 + (x % 3) * 15;
    img.fillCircle(im, x: x, y: y, radius: 14, color: black);
    img.drawLine(im, x1: x + 14, y1: y, x2: x + 14, y2: y - 110, color: black, thickness: 4);
  }
  return im;
}

double psnr(Uint8List a, Uint8List b) {
  var se = 0.0;
  for (int i = 0; i < a.length; i++) {
    final d = a[i] - b[i];
    se += d * d;
  }
  return 10 * math.log(255 * 255 / (se / a.length)) / math.ln10;
}

Uint8List rgbOf(img.Image im) => im.getBytes(order: img.ChannelOrder.rgb);

/// 輝度の勾配エネルギー (輪郭のくっきり度)。
double gradientEnergy(Uint8List rgb, int w, int h) {
  double luma(int x, int y) {
    final i = (y * w + x) * 3;
    return 0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2];
  }

  var e = 0.0;
  for (int y = 1; y < h - 1; y++) {
    for (int x = 1; x < w - 1; x++) {
      final gx = luma(x + 1, y) - luma(x - 1, y);
      final gy = luma(x, y + 1) - luma(x, y - 1);
      e += gx * gx + gy * gy;
    }
  }
  return e / ((w - 2) * (h - 2));
}

void main() {
  const ortPath = 'tools/ort/onnxruntime.dll';
  final model = File(AiSharpen.assetPath);
  final skip = !File(ortPath).existsSync()
      ? 'ORT ライブラリがありません: $ortPath'
      : (!model.existsSync() ? 'モデルがありません' : null);

  test('resizeRgbArea: 縮小は面積平均、同じ大きさはそのまま', () {
    // 2x2 の白黒市松 → 1x1 は灰色
    final src = Uint8List.fromList(<int>[
      0, 0, 0, 255, 255, 255, //
      255, 255, 255, 0, 0, 0,
    ]);
    expect(resizeRgbArea(src, 2, 2, 1, 1), <int>[128, 128, 128]);
    expect(resizeRgbArea(src, 2, 2, 2, 2), src);
    final up = resizeRgbArea(src, 2, 2, 4, 4);
    expect(up.length, 4 * 4 * 3);
  });

  test('ぼけた画像の輪郭がくっきりし、色・位置は保たれる', () {
    const w = 960, h = 540; // 1/2 縮小後 480x270 → タイル 2x2 (境界の継ぎ目も通る)
    final sharp = sharpScore(w, h);
    final truth = rgbOf(sharp);
    final src = rgbOf(img.gaussianBlur(sharp.clone(), radius: 4));
    final progress = <int>[];
    final out = AiSharpen.process(
      src,
      w,
      h,
      model.readAsBytesSync(),
      libraryPath: File(ortPath).absolute.path,
      onProgress: (done, total) => progress.add(done),
    );

    if (Platform.environment['AI_SHARPEN_DUMP'] == '1') {
      img.Image toImg(Uint8List b) => img.Image.fromBytes(
          width: w, height: h, bytes: b.buffer, numChannels: 3);
      File('build/sr/test_in.png').writeAsBytesSync(img.encodePng(toImg(src)));
      File('build/sr/test_out.png').writeAsBytesSync(img.encodePng(toImg(out)));
    }
    expect(out.length, w * h * 3);
    expect(progress, isNotEmpty);
    // 輪郭のくっきり度が上がる
    final before = gradientEnergy(src, w, h);
    final after = gradientEnergy(out, w, h);
    expect(after, greaterThan(before * 1.2), reason: 'before=$before after=$after');
    // ぼける前の画像に近づく (チャンネルの取り違えや位置ずれがあると逆に遠ざかる)
    final pBlur = psnr(src, truth);
    final pOut = psnr(out, truth);
    expect(pOut, greaterThan(pBlur), reason: 'blur=$pBlur out=$pOut');
  }, skip: skip);
}
