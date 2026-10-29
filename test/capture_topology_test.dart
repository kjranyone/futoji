// 撮影から保存・回転までの座標の向き (トポロジ) を通しで検証する。
//
// 座標系と変換 (θ = frameRotationDegrees):
//   センサー全体 S (横長 4:3) ─中央切り出し→ 各ストリーム (解析フレーム F・プレビュー・本撮影)
//   F ─右に θ 回す→ 本撮影画像 J (EXIF 反映済み)。鏡像にはならない
//   プレビュー ─右に θ 回す→ 画面 (フロントカメラはさらに左右反転)
//   J ─切り抜き画面で右に r 回す→ R ─[TL,TR,BR,BL] で台形補正→ 保存ページ O
//   O ─右/左に 90° 回す→ 回したページ (手書きは Stroke.rotated90)
//
// 実機のカメラは使えないので、向きの分かる合成ページ (左上に赤、右上に青の印) を
// センサー画像として作り、画像の回転は image パッケージ (copyRotate) で行う。
// 検出 (DocumentDetector)・写像 (sourceQuadForSave)・台形補正 (warpPerspectiveRgb) は
// アプリと同じ関数を通し、保存されたページで印の位置を確かめる。
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:futoji/models/stroke.dart';
import 'package:futoji/services/auto_capture.dart';
import 'package:futoji/services/detector.dart';
import 'package:futoji/services/image_pipeline.dart';
import 'package:futoji/services/warper.dart';
import 'package:image/image.dart' as img;

/// 紙の置き方。[portrait] は縦長の紙、[tiltDeg] は画面上で右回りの傾き、
/// [offset] は画面中央からのずれ (短辺に対する比率)。
class Paper {
  const Paper({this.portrait = true, this.tiltDeg = 0, this.offset = Offset.zero});
  final bool portrait;
  final double tiltDeg;
  final Offset offset;

  @override
  String toString() =>
      '${portrait ? '縦' : '横'}長 傾き$tiltDeg° ずれ(${offset.dx},${offset.dy})';
}

/// 画面の向き (正立) で見た合成シーン。紙は白、地は暗い灰色、
/// 紙の左上に赤、右上に青の印がある (紙の座標で決めるので、紙と一緒に傾く)。
img.Image drawScene(int w, int h, Paper paper) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(50, 50, 50));
  final short = math.min(w, h).toDouble();
  final pw = short * (paper.portrait ? 0.36 : 0.36 * math.sqrt2);
  final ph = short * (paper.portrait ? 0.36 * math.sqrt2 : 0.36);
  final cx = w / 2 + paper.offset.dx * short;
  final cy = h / 2 + paper.offset.dy * short;
  final t = paper.tiltDeg * math.pi / 180;
  final cosT = math.cos(t), sinT = math.sin(t);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      // 画面 → 紙の座標 (u: 左→右, v: 上→下、0..1)
      final dx = x + 0.5 - cx, dy = y + 0.5 - cy;
      final u = (dx * cosT + dy * sinT) / pw + 0.5;
      final v = (-dx * sinT + dy * cosT) / ph + 0.5;
      if (u < 0 || u > 1 || v < 0 || v > 1) continue;
      var c = img.ColorRgb8(235, 235, 235);
      if (u > 0.1 && u < 0.35 && v > 0.08 && v < 0.25) c = img.ColorRgb8(210, 30, 30);
      if (u > 0.7 && u < 0.9 && v > 0.08 && v < 0.2) c = img.ColorRgb8(30, 30, 210);
      im.setPixel(x, y, c);
    }
  }
  return im;
}

/// センサー全体 (横長 [kSensorAspect]) から、アスペクト比 [aspect] (横長) のストリームを
/// 中央で最大に切り出す (CameraX の各ストリームと同じ写り方)。
img.Image cropStream(img.Image sensor, double aspect) {
  final sw = sensor.width, sh = sensor.height;
  var w = sw, h = sh;
  if (aspect > sw / sh) {
    h = (sw / aspect).round();
  } else {
    w = (sh * aspect).round();
  }
  return img.copyCrop(sensor, x: (sw - w) ~/ 2, y: (sh - h) ~/ 2, width: w, height: h);
}

img.Image rotateCw(img.Image im, int deg) =>
    deg % 360 == 0 ? im : img.copyRotate(im, angle: deg % 360);

/// 台形補正の結果から印の重心を探す (正規化座標)。見つからなければ null。
({Offset? red, Offset? blue}) findMarks(List<int> rgb, int w, int h) {
  double rx = 0, ry = 0, bx = 0, by = 0;
  int rn = 0, bn = 0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final i = (y * w + x) * 3;
      final r = rgb[i], g = rgb[i + 1], b = rgb[i + 2];
      if (r > 150 && g < 90 && b < 90) {
        rx += x;
        ry += y;
        rn++;
      } else if (b > 150 && r < 90 && g < 90) {
        bx += x;
        by += y;
        bn++;
      }
    }
  }
  return (
    red: rn < 20 ? null : Offset(rx / rn / w, ry / rn / h),
    blue: bn < 20 ? null : Offset(bx / bn / w, by / bn / h),
  );
}

/// 保存されたページ: 画像 [src] と四隅 (画素座標) から台形補正する。
({List<int> rgb, int w, int h}) warp(img.Image src, List<Offset> quad) {
  final size = outputSizeForQuad(quad, maxSide: 400, minSide: 120);
  final w = size.width.round(), h = size.height.round();
  final rgb = warpPerspectiveRgb(
    src: src.getBytes(),
    srcW: src.width,
    srcH: src.height,
    numCh: src.numChannels,
    srcQuad: quad,
    outW: w,
    outH: h,
  );
  return (rgb: rgb, w: w, h: h);
}

List<Offset> detect(img.Image im) {
  final corners = DocumentDetector.detectLuminance(
      DocumentDetector.toGray(im), im.width, im.height);
  expect(corners, isNotNull, reason: '合成画像で紙が検出できない');
  return corners!;
}

/// 正規化座標の点を、画像ごと右に [deg] 度回したときの位置 (90° の繰り返しで定義)。
Offset rotatePointCw(Offset p, int deg) {
  var q = p;
  for (int i = 0; i < (deg % 360) ~/ 90; i++) {
    q = Offset(1 - q.dy, q.dx);
  }
  return q;
}

/// センサー全体の正規化座標を、ストリーム (横長 [aspect]) の正規化座標へ。
Offset sensorToStream(Offset s, double aspect) {
  if (aspect > kSensorAspect) {
    final span = kSensorAspect / aspect; // 写っている高さの割合
    return Offset(s.dx, 0.5 + (s.dy - 0.5) / span);
  }
  final span = aspect / kSensorAspect; // 写っている幅の割合
  return Offset(0.5 + (s.dx - 0.5) / span, s.dy);
}

/// ページの向きの期待値: 紙を [turns] × 90° 右に回して見たとき、赤・青の印がある象限。
void expectUpright(({List<int> rgb, int w, int h}) page, String label, {int turns = 0}) {
  final marks = findMarks(page.rgb, page.w, page.h);
  expect(marks.red, isNotNull, reason: '$label: 赤の印が保存範囲にない');
  expect(marks.blue, isNotNull, reason: '$label: 青の印が保存範囲にない');
  // 紙の座標での印の位置を回して、保存ページ上の期待位置にする
  final wantRed = rotatePointCw(const Offset(0.22, 0.16), turns * 90);
  final wantBlue = rotatePointCw(const Offset(0.8, 0.14), turns * 90);
  expect((marks.red! - wantRed).distance, lessThan(0.12),
      reason: '$label: 赤の印 ${marks.red} (期待 $wantRed)');
  expect((marks.blue! - wantBlue).distance, lessThan(0.12),
      reason: '$label: 青の印 ${marks.blue} (期待 $wantBlue)');
}

const papers = <Paper>[
  Paper(),
  Paper(tiltDeg: 18, offset: Offset(0.05, -0.04)),
  Paper(tiltDeg: -22, offset: Offset(-0.04, 0.05)),
  Paper(portrait: false, tiltDeg: 10),
];

void main() {
  test('前提: image パッケージの copyRotate は右回り', () {
    final im = img.Image(width: 4, height: 2);
    im.setPixelRgb(0, 0, 255, 0, 0); // 左上
    final r = img.copyRotate(im, angle: 90);
    expect(r.width, 2);
    expect(r.height, 4);
    expect(r.getPixel(1, 0).r, 255); // 右回りなら左上は右上へ
    expect(rotatePointCw(const Offset(0, 0), 90), const Offset(1, 0));
  });

  group('frameRotationDegrees (CameraX と同じ式)', () {
    test('縦が基本のスマホを縦向き: 背面 90° / 前面 270°', () {
      expect(frameRotationDegrees(sensorOrientation: 90, displayRotation: 0, frontFacing: false), 90);
      expect(frameRotationDegrees(sensorOrientation: 270, displayRotation: 0, frontFacing: true), 270);
    });

    test('画面を左に倒して横向き (ROTATION_90): 背面はセンサーの向きそのまま', () {
      // センサーの上辺が端末の右辺 (sensor 90)。端末を左に倒すと右辺が上になり、回転は不要
      expect(frameRotationDegrees(sensorOrientation: 90, displayRotation: 90, frontFacing: false), 0);
      expect(frameRotationDegrees(sensorOrientation: 270, displayRotation: 90, frontFacing: true), 0);
    });

    test('横が基本のタブレット (sensor 0) を縦向きにすると 90° / 270° 回す', () {
      expect(frameRotationDegrees(sensorOrientation: 0, displayRotation: 270, frontFacing: false), 90);
      expect(frameRotationDegrees(sensorOrientation: 0, displayRotation: 90, frontFacing: false), 270);
    });
  });

  group('ライブ枠: フレーム → プレビュー (画面) の位置', () {
    // センサー上の点が、フレームとプレビューでそれぞれどこに写るかから期待値を作る
    const points = <Offset>[Offset(0.3, 0.4), Offset(0.62, 0.71), Offset(0.5, 0.5)];
    for (final rotation in const <int>[0, 90, 180, 270]) {
      for (final mirror in const <bool>[false, true]) {
        for (final (frameAspect, previewAspect) in const <(double, double)>[
          (4 / 3, 4 / 3),
          (16 / 9, 4 / 3),
          (4 / 3, 16 / 9),
          (1.0, 4 / 3),
        ]) {
          test('θ=$rotation 鏡像=$mirror フレーム$frameAspect プレビュー$previewAspect', () {
            final quarter = rotation % 180 != 0;
            final boxAspect = quarter ? 1 / previewAspect : previewAspect;
            for (final s in points) {
              final f = sensorToStream(s, frameAspect);
              var want = rotatePointCw(sensorToStream(s, previewAspect), rotation);
              if (mirror) want = Offset(1 - want.dx, want.dy);
              final got = frameToPreview(f, (frameAspect * 300).round(), 300, rotation,
                  boxAspect, mirror: mirror);
              expect((got - want).distance, lessThan(0.01), reason: 'センサー上の点 $s');
            }
          });
        }
      }
    }
  });

  group('自動撮影: フレームで検出した枠で本撮影画像を保存', () {
    for (final rotation in const <int>[90, 270, 0, 180]) {
      for (final (frameAspect, jpegAspect) in const <(double, double)>[
        (4 / 3, 4 / 3),
        (16 / 9, 4 / 3),
        (4 / 3, 16 / 9),
      ]) {
        for (final paper in papers) {
          test('θ=$rotation フレーム$frameAspect 本撮影$jpegAspect $paper', () {
            // 画面の向きで見たセンサー全体のシーンを作り、センサーの向きへ戻す
            final quarter = rotation % 180 != 0;
            final scene = quarter ? drawScene(300, 400, paper) : drawScene(400, 300, paper);
            final sensor = rotateCw(scene, 360 - rotation);
            final frame = cropStream(sensor, frameAspect);
            final jpeg = rotateCw(cropStream(sensor, jpegAspect), rotation);

            final quad = sourceQuadForSave(
              corners: detect(frame),
              rotationDeg: 0,
              imageW: jpeg.width,
              imageH: jpeg.height,
              frameW: frame.width,
              frameH: frame.height,
              frameRotation: rotation,
            );
            final page = warp(jpeg, quad);
            expect(page.h > page.w, paper.portrait, reason: '縦長・横長が保たれる');
            expectUpright(page, '$paper');
          });
        }
      }
    }
  });

  group('切り抜き画面: 回した画像で検出・確定した枠で保存', () {
    for (final r in const <int>[0, 90, 180, 270]) {
      for (final paper in papers) {
        test('回転 $r° $paper', () {
          final jpeg = drawScene(300, 400, paper);
          final rotated = rotateCw(jpeg, r); // 切り抜き画面に表示する画像
          final quad = sourceQuadForSave(
            corners: detect(rotated),
            rotationDeg: r,
            imageW: rotated.width,
            imageH: rotated.height,
          );
          // パイプラインは本撮影画像を同じ角度で回してから台形補正する
          final page = warp(rotateCw(jpeg, r), quad);
          // 画面で見ていたとおり (紙を r 回した向き) に保存される
          expectUpright(page, '$paper', turns: r ~/ 90);
        });
      }
    }
  });

  group('保存後の回転: 画像と手書きが同じように回る', () {
    for (final clockwise in const <bool>[true, false]) {
      test(clockwise ? '右に回す' : '左に回す', () {
        // 画像の回転は Android の Matrix.setRotate (正 = 右回り)。ここでは copyRotate で代用する
        const w = 40, h = 30;
        const points = <Offset>[Offset(0.1, 0.2), Offset(0.8, 0.3), Offset(0.45, 0.9)];
        for (final p in points) {
          final im = img.Image(width: w, height: h);
          final px = (p.dx * w).floor(), py = (p.dy * h).floor();
          im.setPixelRgb(px, py, 255, 0, 0);
          final turned = img.copyRotate(im, angle: clockwise ? 90 : 270);
          var found = Offset.zero;
          for (final q in turned) {
            if (q.r > 0) found = Offset((q.x + 0.5) / turned.width, (q.y + 0.5) / turned.height);
          }
          final stroke = Stroke(color: 0, width: 0.01, points: <Offset>[
            Offset((px + 0.5) / w, (py + 0.5) / h),
          ]).rotated90(clockwise: clockwise, pageAspect: w / h);
          expect((stroke.points.single - found).distance, lessThan(1e-9), reason: '$p');
          // 線の太さ (px) も変わらない: 回す前は幅 w 基準、回した後は幅 h 基準
          expect(stroke.width * h, closeTo(0.01 * w, 1e-9));
        }
      });
    }
  });
}
