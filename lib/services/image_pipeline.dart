import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

import '../models/crop_result.dart';
import 'auto_capture.dart';
import 'color_quantizer.dart';
import 'storage.dart';
import 'warper.dart';

class ScanResult {
  ScanResult({
    required this.imageFile,
    required this.thumbFile,
    required this.width,
    required this.height,
  });

  final File imageFile;
  final File thumbFile;
  final int width;
  final int height;
}

class _Prepared {
  _Prepared({
    required this.fullJpg,
    required this.thumbJpg,
    required this.width,
    required this.height,
  });

  final Uint8List fullJpg;
  final Uint8List thumbJpg;
  final int width;
  final int height;
}

/// 撮影 1 枚を「デコード → 回転 → 台形補正 → WebP 保存」まで処理する。
///
/// cornersNormalized は「回転後」の画像に対する 0..1 正規化座標 ([TL,TR,BR,BL])。
class ImagePipeline {
  /// 重い処理は Isolate で実行して UI を止めない。
  static Future<ScanResult> processAndSave({
    required File rawFile,
    required List<Offset> cornersNormalized,
    required int rotationDeg,
    required String pageId,
    CropResult? liveFrame,
    bool reduceColors = false,
  }) async {
    final bytes = await rawFile.readAsBytes();
    final corners = <List<double>>[
      for (final c in cornersNormalized) <double>[c.dx, c.dy],
    ];

    // dart:ui の型は isolate を跨がせないためプレーンな list で渡す。
    // クロージャが this を拾わないよう top-level 関数を呼ぶ。
    final frame = liveFrame == null
        ? null
        : <Object?>[
            liveFrame.frameWidth ?? 0,
            liveFrame.frameHeight ?? 0,
            liveFrame.sensorOrientation ?? 0,
          ];
    final prepared = await Isolate.run(
        () => _prepareScanData(bytes, corners, rotationDeg, frame, reduceColors));

    // WebP エンコードはネイティブ (プラットフォームチャネル) なのでメイン isolate で
    final fullWebp = await FlutterImageCompress.compressWithList(
      prepared.fullJpg,
      quality: 84,
      format: CompressFormat.webp,
    );
    final thumbWebp = await FlutterImageCompress.compressWithList(
      prepared.thumbJpg,
      quality: 80,
      format: CompressFormat.webp,
    );

    final imageFile = File(AppPaths.imagePathFor(pageId));
    await imageFile.writeAsBytes(fullWebp);
    final thumbFile = File(AppPaths.thumbPathFor(pageId));
    await thumbFile.writeAsBytes(thumbWebp);

    return ScanResult(
      imageFile: imageFile,
      thumbFile: thumbFile,
      width: prepared.width,
      height: prepared.height,
    );
  }
}

/// isolate 上で実行する重い前処理 (デコード→回転→台形補正→JPEG化)。
/// クロージャ経由で this を送らないよう top-level 関数にしてある。
_Prepared _prepareScanData(Uint8List bytes, List<List<double>> corners,
    int rotationDeg, List<Object?>? frame, bool reduceColors) {
    final decoded = img.decodeJpg(bytes);
    if (decoded == null) {
      throw const FormatException('撮影画像を解析できませんでした');
    }
    var im = img.bakeOrientation(decoded);

    // 処理・保存の上限 (長辺 2600px)。A4 を 300dpi 相当よりやや粗めにした上限。
    const cap = 2600;
    final long = math.max(im.width, im.height);
    if (long > cap) {
      im = im.width >= im.height
          ? img.copyResize(im, width: cap, interpolation: img.Interpolation.average)
          : img.copyResize(im, height: cap, interpolation: img.Interpolation.average);
    }

    if (rotationDeg != 0) {
      im = img.copyRotate(im, angle: rotationDeg);
    }

    final srcW = im.width;
    final srcH = im.height;
    // corners がライブ検出フレーム由来の場合はセンサー向き・中心クロップを補正
    var normalized = <Offset>[
      for (final c in corners) Offset(c[0], c[1]),
    ];
    if (frame != null) {
      final fw = frame[0] as int;
      final fh = frame[1] as int;
      final so = frame[2] as int;
      if (fw > 0 && fh > 0) {
        normalized = mapFrameCornersToImage(
          corners: normalized,
          frameW: fw,
          frameH: fh,
          sensorOrientation: so,
          imageAspect: srcW / srcH,
        );
      }
    }
    final quad = <Offset>[
      for (final c in normalized) Offset(c.dx * srcW, c.dy * srcH),
    ];

    final size = outputSizeForQuad(quad);
    final outW = size.width.round();
    final outH = size.height.round();

    final warpedBytes = warpPerspectiveRgb(
      src: im.getBytes(),
      srcW: srcW,
      srcH: srcH,
      numCh: im.numChannels,
      srcQuad: quad,
      outW: outW,
      outH: outH,
    );

    // 減色オプション: 色域を分析してパレット数を自動決定し、色数を絞る
    // (白黒文書は 8 色程度に収まり、ファイルも小さくなる)
    // img.Image.fromBytes はバッファをコピーするので、必ずその前に行う。
    if (reduceColors) {
      final paletteSize = ColorQuantizer.decidePaletteSize(warpedBytes);
      if (paletteSize >= 2) {
        ColorQuantizer.quantize(warpedBytes, paletteSize);
      }
    }

    final warped = img.Image.fromBytes(
      width: outW,
      height: outH,
      bytes: warpedBytes.buffer,
      numChannels: 3,
    );

    final fullJpg = Uint8List.fromList(img.encodeJpg(warped, quality: 92));

    // サムネイル (長辺 420px)
    var thumb = warped;
    final thumbCap = 420;
    final thumbLong = math.max(warped.width, warped.height);
    if (thumbLong > thumbCap) {
      thumb = warped.width >= warped.height
          ? img.copyResize(warped,
              width: thumbCap, interpolation: img.Interpolation.average)
          : img.copyResize(warped,
              height: thumbCap, interpolation: img.Interpolation.average);
    }
    final thumbJpg = Uint8List.fromList(img.encodeJpg(thumb, quality: 82));

    return _Prepared(
      fullJpg: fullJpg,
      thumbJpg: thumbJpg,
      width: outW,
      height: outH,
    );
}

