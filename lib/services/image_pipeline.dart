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
import 'raster.dart';
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
            liveFrame.frameRotation ?? 0,
          ];
    // デコードは端末のデコーダで縮小しながら行う (純 Dart の全画素デコードは
    // 実機で約 11 秒かかっていた)。長辺 2600px は A4 を 300dpi よりやや粗めにした上限。
    final decoded = await decodeImageCapped(bytes, cap: _saveCap);
    lap('decode');
    final focal35 = _focal35mmOf(bytes);
    final ai = aiSharpen ? await _aiArgs() : null;
    final prepared = await Isolate.run(() => _prepareScanData(
        decoded, corners, rotationDeg, frame, reduceColors, ai, dewarp, focal35));
    lap('isolate');
    timings?.addAll(prepared.timings);

    // WebP エンコードはネイティブ (プラットフォームチャネル) なのでメイン isolate で。
    // プラグインは Android 側のスレッドプールで処理するので、本体とサムネイルを同時に投げる
    final webpWatch = Stopwatch()..start();
    final thumbFuture = FlutterImageCompress.compressWithList(
      prepared.thumbBmp,
      quality: 80,
      format: CompressFormat.webp,
    ).whenComplete(() => timings?['webp_thumb'] = webpWatch.elapsedMilliseconds);
    final fullWebp = await FlutterImageCompress.compressWithList(
      prepared.fullBmp,
      quality: 84,
      format: CompressFormat.webp,
    );
    timings?['webp_full'] = webpWatch.elapsedMilliseconds;
    final thumbWebp = await thumbFuture;
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

  /// 保存済みの WebP を [angle] 度 (右回り) 回して [dst] に書く。縮小はしない。
  static Future<void> rotateSaved(String src, String dst, int angle,
      {required int quality}) async {
    final out = await FlutterImageCompress.compressAndGetFile(
      src,
      dst,
      // 縮小の基準より大きくして、元の大きさのまま回す
      minWidth: 1 << 16,
      minHeight: 1 << 16,
      quality: quality,
      rotate: angle,
      autoCorrectionAngle: false,
      format: CompressFormat.webp,
    );
    if (out == null) throw StateError('ページの回転に失敗しました: $src');
  }
}

/// 台形補正に渡す四隅 (画素座標、[TL,TR,BR,BL])。
/// [corners] は切り抜き画面なら [rotationDeg] 回した画像 ([imageW] x [imageH]) 上の
/// 正規化座標。ライブ検出の枠 ([frameW] があるとき) ならフレーム上の正規化座標なので、
/// フレームの向き ([frameRotation]) と [rotationDeg] を合わせて回し、画像の座標へ写す。
List<Offset> sourceQuadForSave({
  required List<Offset> corners,
  required int rotationDeg,
  required int imageW,
  required int imageH,
  int? frameW,
  int? frameH,
  int? frameRotation,
}) {
  var normalized = corners;
  if (frameW != null && frameH != null && frameW > 0 && frameH > 0) {
    normalized = mapFrameCornersToImage(
      corners: corners,
      frameW: frameW,
      frameH: frameH,
      rotation: (frameRotation ?? 0) + rotationDeg,
      imageAspect: imageW / imageH,
    );
  }
  return <Offset>[
    for (final c in normalized) Offset(c.dx * imageW, c.dy * imageH),
  ];
}

/// 写真の EXIF にある 35mm 換算の焦点距離 (縦横比の推定に使う)。なければ null。
double? _focal35mmOf(Uint8List bytes) {
  try {
    final v = img.decodeJpgExif(bytes)?.exifIfd['FocalLengthIn35mmFilm']?.toInt();
    return v != null && v > 0 ? v.toDouble() : null;
  } catch (_) {
    return null;
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
Future<PageDewarp?> estimateDewarpForQuad({
  required Uint8List src,
  required int srcW,
  required int srcH,
  required int numCh,
  required List<Offset> srcQuad,
  required int outW,
  required int outH,
  int? workers,
}) {
  const w = StaffDewarp.workWidth;
  final h = math.max(16, (outH * w / outW).round());
  final gray = warpPerspectiveGray(
    src: src,
    srcW: srcW,
    srcH: srcH,
    numCh: numCh,
    srcQuad: srcQuad,
    outW: w,
    outH: h,
  );
  return StaffDewarp.estimate(gray, w, h,
      workers: workers ?? StaffDewarp.defaultWorkers);
}

/// isolate 上で実行する重い前処理 (回転→台形補正→BMP化)。
/// [decoded] は正立・長辺 [_saveCap] 以下にデコード済みの画像。
/// クロージャ経由で this を送らないよう top-level 関数にしてある。
Future<_Prepared> _prepareScanData(img.Image decoded, List<List<double>> corners,
    int rotationDeg, List<Object?>? frame, bool reduceColors, List<Object?>? ai,
    bool dewarp, double? focal35) async {
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
    final quad = sourceQuadForSave(
      corners: <Offset>[
        for (final c in corners) Offset(c[0], c[1]),
      ],
      rotationDeg: rotationDeg,
      imageW: srcW,
      imageH: srcH,
      frameW: frame?[0] as int?,
      frameH: frame?[1] as int?,
      frameRotation: frame?[2] as int?,
    );

    // 斜めから撮っても潰れないよう、透視から紙の本来の縦横比を推定して出力サイズを決める
    final aspect = estimateQuadAspect(quad,
        imageW: srcW.toDouble(),
        imageH: srcH.toDouble(),
        focalPx: focalPxFrom35mm(
            focal35 ?? kDefaultFocal35mm, srcW.toDouble(), srcH.toDouble()));
    final size = outputSizeForQuad(quad,
        aspect: aspect == null ? null : snapToPaperAspect(aspect));
    final outW = size.width.round();
    final outH = size.height.round();

    final srcBytes = im.getBytes();
    // 曲がり補正 (設定で ON のとき)。失敗しても台形補正だけで保存を続ける
    PageDewarp? field;
    if (dewarp) {
      try {
        field = await estimateDewarpForQuad(
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
    // BMP 化・サムネイル作成より前に行う (どちらも warpedBytes から作る)。
    if (reduceColors) {
      final paletteSize = ColorQuantizer.decidePaletteSize(warpedBytes);
      if (paletteSize >= 2) {
        ColorQuantizer.quantize(warpedBytes, paletteSize);
      }
    }

    lap('quantize');
    // WebP 変換 (ネイティブ) に渡すための中間形式。純 Dart の JPEG エンコードは
    // 実機 2 秒前後かかっていたため、ほぼコピーだけで作れる無圧縮 BMP にする。
    final fullBmp = encodeBmp24(warpedBytes, outW, outH);
    lap('bmp');

    // サムネイル (長辺 420px, 面積平均)
    final (thumbRgb, tw, th) = downscaleRgbBox(warpedBytes, outW, outH, 420);
    final thumbBmp = encodeBmp24(thumbRgb, tw, th);
    lap('thumb');

    return _Prepared(
      fullBmp: fullBmp,
      thumbBmp: thumbBmp,
      width: outW,
      height: outH,
      timings: timings,
    );
}

