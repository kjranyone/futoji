// ライブ検出のフレーム (CameraImage) を色付きの画素列にする変換 (extractFramePixels) を検証する。
// 紙 (白) と机 (ベージュ) の色の違いがそのまま RGB に残ることを、平面の並び方ごとに確かめる。
// ignore_for_file: deprecated_member_use
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futoji/services/detection_worker.dart';

const desk = <int>[200, 188, 158]; // ベージュの机
const paper = <int>[214, 216, 220]; // 少し青みのある白い紙

/// RGB → YUV (BT.601)。[video] ならビデオレンジ (Y 16〜235、色差 16〜240)。
List<double> yuvOf(List<int> rgb, {bool video = false}) {
  final r = rgb[0], g = rgb[1], b = rgb[2];
  var y = 0.299 * r + 0.587 * g + 0.114 * b;
  var u = (b - y) / 1.772;
  var v = (r - y) / 1.402;
  if (video) {
    y = 16 + y * 219 / 255;
    u = u * 224 / 255;
    v = v * 224 / 255;
  }
  return <double>[y, u + 128, v + 128];
}

/// 左半分が机、右半分が紙の w x h のフレーム。
List<int> colorAt(int x, int w) => x < w ~/ 2 ? desk : paper;

/// Android の YUV_420_888。[interleaved] なら U/V が 1 バイトおきに交互 (NV21 と同じ並び)。
CameraImage androidYuv(int w, int h, {required bool interleaved, int rowPad = 8}) {
  final yRow = w + rowPad;
  final yBytes = Uint8List(yRow * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      yBytes[y * yRow + x] = yuvOf(colorAt(x, w))[0].round();
    }
  }
  final cw = w ~/ 2, ch = h ~/ 2;
  final Uint8List uBytes, vBytes;
  final int cRow, cPix;
  if (interleaved) {
    // V, U, V, U ... の 1 つのバッファを、U は 1 バイト目から、V は 0 バイト目から見る
    cRow = w + rowPad;
    cPix = 2;
    final vu = Uint8List(cRow * ch);
    for (int y = 0; y < ch; y++) {
      for (int x = 0; x < cw; x++) {
        final c = yuvOf(colorAt(x * 2, w));
        vu[y * cRow + x * 2] = c[2].round();
        vu[y * cRow + x * 2 + 1] = c[1].round();
      }
    }
    vBytes = vu;
    // 実機と同じく、U 平面は V 平面の 1 バイト後ろから始まり、末尾が 1 バイト短い
    uBytes = Uint8List.sublistView(vu, 1);
  } else {
    cRow = cw + rowPad;
    cPix = 1;
    uBytes = Uint8List(cRow * ch);
    vBytes = Uint8List(cRow * ch);
    for (int y = 0; y < ch; y++) {
      for (int x = 0; x < cw; x++) {
        final c = yuvOf(colorAt(x * 2, w));
        uBytes[y * cRow + x] = c[1].round();
        vBytes[y * cRow + x] = c[2].round();
      }
    }
  }
  return CameraImage.fromPlatformData(<String, Object>{
    'format': 35, // YUV_420_888
    'width': w,
    'height': h,
    'planes': <Map<String, Object>>[
      <String, Object>{'bytes': yBytes, 'bytesPerRow': yRow, 'bytesPerPixel': 1},
      <String, Object>{'bytes': uBytes, 'bytesPerRow': cRow, 'bytesPerPixel': cPix},
      <String, Object>{'bytes': vBytes, 'bytesPerRow': cRow, 'bytesPerPixel': cPix},
    ],
  });
}

void expectHalves(Uint8List px, int dw, int dh, {int tol = 3}) {
  for (final (x, want) in <(int, List<int>)>[(dw ~/ 4, desk), (dw * 3 ~/ 4, paper)]) {
    final i = ((dh ~/ 2) * dw + x) * 3;
    for (int c = 0; c < 3; c++) {
      expect((px[i + c] - want[c]).abs(), lessThanOrEqualTo(tol),
          reason: 'x=$x ch=$c: ${px.sublist(i, i + 3)} (期待 $want)');
    }
  }
}

void main() {
  const w = 64, h = 48;

  for (final interleaved in const <bool>[false, true]) {
    test('Android の YUV_420_888 (${interleaved ? 'U/V 交互' : 'U/V 別平面'}) は RGB になる', () {
      final (px, dw, dh, ch) =
          extractFramePixels(androidYuv(w, h, interleaved: interleaved), decimate: 4);
      expect((dw, dh, ch), (w ~/ 4, h ~/ 4, 3));
      expectHalves(px, dw, dh);
    });
  }

  test('iOS の 2 平面 (ビデオレンジ) も RGB になる', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final yBytes = Uint8List(w * h);
    final cbcr = Uint8List(w * (h ~/ 2));
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        yBytes[y * w + x] = yuvOf(colorAt(x, w), video: true)[0].round();
      }
    }
    for (int y = 0; y < h ~/ 2; y++) {
      for (int x = 0; x < w ~/ 2; x++) {
        final c = yuvOf(colorAt(x * 2, w), video: true);
        cbcr[y * w + x * 2] = c[1].round();
        cbcr[y * w + x * 2 + 1] = c[2].round();
      }
    }
    final image = CameraImage.fromPlatformData(<String, Object>{
      'format': 875704438, // 420YpCbCr8BiPlanarVideoRange
      'width': w,
      'height': h,
      'planes': <Map<String, Object>>[
        <String, Object>{'bytes': yBytes, 'bytesPerRow': w},
        <String, Object>{'bytes': cbcr, 'bytesPerRow': w},
      ],
    });
    final (px, dw, dh, ch) = extractFramePixels(image, decimate: 2);
    expect(ch, 3);
    expectHalves(px, dw, dh);
  });

  test('色の取れない形式は Y 平面の灰色 (1ch)', () {
    final yBytes = Uint8List(w * h)..fillRange(0, w * h, 120);
    final image = CameraImage.fromPlatformData(<String, Object>{
      'format': 256, // JPEG (色差の平面がない)
      'width': w,
      'height': h,
      'planes': <Map<String, Object>>[
        <String, Object>{'bytes': yBytes, 'bytesPerRow': w, 'bytesPerPixel': 1},
      ],
    });
    final (px, dw, dh, ch) = extractFramePixels(image, decimate: 2);
    expect((dw, dh, ch), (w ~/ 2, h ~/ 2, 1));
    expect(px.every((v) => v == 120), isTrue);
  });
}
