import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;

import '../models/crop_result.dart';
import 'ai_sharpen.dart';
import 'auto_capture.dart';
import 'color_quantizer.dart';
import 'fast_decode.dart';
import 'ort_ffi.dart';
import 'staff_dewarp.dart';
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
    required this.fullBmp,
    required this.thumbBmp,
    required this.width,
    required this.height,
    this.timings = const <String, int>{},
  });

  final Uint8List fullBmp;
  final Uint8List thumbBmp;
  final int width;
  final int height;

  /// 工程ごとの所要時間 (ms)。自己診断で実機の内訳を見るため。
  final Map<String, int> timings;
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
    bool aiSharpen = false,
    bool dewarp = false,
    Map<String, int>? timings,
  }) async {
    final sw = Stopwatch()..start();
    void lap(String name) {
      timings?[name] = sw.elapsedMilliseconds;
      sw
        ..reset()
        ..start();
    }

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
    // デコードは端末のデコーダで縮小しながら行う (純 Dart の全画素デコードは
    // 実機で約 11 秒かかっていた)。長辺 2600px は A4 を 300dpi よりやや粗めにした上限。
    final decoded = await decodeImageCapped(bytes, cap: _saveCap);
    lap('decode');
    final ai = aiSharpen ? await _aiArgs() : null;
    final prepared = await Isolate.run(() => _prepareScanData(
        decoded, corners, rotationDeg, frame, reduceColors, ai, dewarp));
    lap('isolate');
    timings?.addAll(prepared.timings);

    // WebP エンコードはネイティブ (プラットフォームチャネル) なのでメイン isolate で
    final fullWebp = await FlutterImageCompress.compressWithList(
      prepared.fullBmp,
      quality: 84,
      format: CompressFormat.webp,
    );
    final thumbWebp = await FlutterImageCompress.compressWithList(
      prepared.thumbBmp,
      quality: 80,
      format: CompressFormat.webp,
    );

    lap('webp');
    final imageFile = File(AppPaths.imagePathFor(pageId));
    await imageFile.writeAsBytes(fullWebp);
    final thumbFile = File(AppPaths.thumbPathFor(pageId));
    await thumbFile.writeAsBytes(thumbWebp);
    lap('write');

    return ScanResult(
      imageFile: imageFile,
      thumbFile: thumbFile,
      width: prepared.width,
      height: prepared.height,
    );
  }
}

/// 保存画像の長辺上限。
const int _saveCap = 2600;

Uint8List? _aiModel;

/// AI シャープ化を isolate で動かすための [モデル, ORT の入口アドレス (iOS)]。
/// 読めなければ null (AI なしで保存する)。
Future<List<Object?>?> _aiArgs() async {
  try {
    _aiModel ??= (await rootBundle.load(AiSharpen.assetPath)).buffer.asUint8List();
    await OrtApiBindings.preparePlatform();
    return <Object?>[_aiModel, OrtApiBindings.iosApiBaseAddress];
  } catch (e) {
    debugPrint('AiSharpen: unavailable ($e)');
    return null;
  }
}

/// 台形補正後の画像にかける湾曲補正 (五線ベース) を推定する。
/// 検出用に幅 [StaffDewarp.workWidth] の台形補正済みグレースケールを作って推定し、
/// 結果は正規化座標なので保存サイズの台形補正にそのまま使える。
/// 五線が見つからない・推定が怪しいときは null (補正しない)。
PageDewarp? estimateDewarpForQuad({
  required Uint8List src,
  required int srcW,
  required int srcH,
  required int numCh,
  required List<Offset> srcQuad,
  required int outW,
  required int outH,
}) {
  const w = StaffDewarp.workWidth;
  final h = math.max(16, (outH * w / outW).round());
  final rgb = warpPerspectiveRgb(
    src: src,
    srcW: srcW,
    srcH: srcH,
    numCh: numCh,
    srcQuad: srcQuad,
    outW: w,
    outH: h,
  );
  final gray = Uint8List(w * h);
  for (int i = 0; i < w * h; i++) {
    gray[i] = (0.299 * rgb[i * 3] + 0.587 * rgb[i * 3 + 1] + 0.114 * rgb[i * 3 + 2])
        .round();
  }
  return StaffDewarp.estimate(gray, w, h);
}

/// isolate 上で実行する重い前処理 (回転→台形補正→BMP化)。
/// [decoded] は正立・長辺 [_saveCap] 以下にデコード済みの画像。
/// クロージャ経由で this を送らないよう top-level 関数にしてある。
_Prepared _prepareScanData(img.Image decoded, List<List<double>> corners,
    int rotationDeg, List<Object?>? frame, bool reduceColors, List<Object?>? ai,
    bool dewarp) {
    final timings = <String, int>{};
    final sw = Stopwatch()..start();
    void lap(String name) {
      timings['iso_$name'] = sw.elapsedMilliseconds;
      sw
        ..reset()
        ..start();
    }

    var im = decoded;

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

    final srcBytes = im.getBytes();
    // 曲がり補正 (設定で ON のとき)。失敗しても台形補正だけで保存を続ける
    PageDewarp? field;
    if (dewarp) {
      try {
        field = estimateDewarpForQuad(
          src: srcBytes,
          srcW: srcW,
          srcH: srcH,
          numCh: im.numChannels,
          srcQuad: quad,
          outW: outW,
          outH: outH,
        );
      } catch (e) {
        debugPrint('StaffDewarp: failed ($e)');
      }
      lap(field == null ? 'dewarp_none' : 'dewarp');
    }

    var warpedBytes = warpPerspectiveRgb(
      src: srcBytes,
      srcW: srcW,
      srcH: srcH,
      numCh: im.numChannels,
      srcQuad: quad,
      outW: outW,
      outH: outH,
      dewarp: field,
    );
    lap('warp');

    // AI シャープ化 (設定で ON のとき)。失敗しても補正済みの画像で保存を続ける
    if (ai != null) {
      try {
        warpedBytes = AiSharpen.process(warpedBytes, outW, outH, ai[0] as Uint8List,
            apiBaseAddress: ai[1] as int?);
      } catch (e) {
        debugPrint('AiSharpen: failed ($e)');
      }
      lap('ai');
    }

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

    lap('quantize');
    // WebP 変換 (ネイティブ) に渡すための中間形式。純 Dart の JPEG エンコードは
    // 実機 2 秒前後かかっていたため、ほぼコピーだけで作れる無圧縮 BMP にする。
    final fullBmp = Uint8List.fromList(img.encodeBmp(warped));
    lap('bmp');

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
    final thumbBmp = Uint8List.fromList(img.encodeBmp(thumb));
    lap('thumb');

    return _Prepared(
      fullBmp: fullBmp,
      thumbBmp: thumbBmp,
      width: outW,
      height: outH,
      timings: timings,
    );
}

