import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;

import 'ort_ffi.dart';

/// ONNX の TinyUNet で「紙マスク」を推論し、四隅 (正規化座標) を返すサービス。
///
/// 推論は dart:ffi で ORT の C API を直接叩く (Java/JNI を経由しない)。
/// flutter_onnxruntime の Java 層はリリースビルドで JNI クラッシュするため置き換え。
/// モデルは assets/models/paper_seg.onnx、入出力とも 1x1x256x256 の float32。
/// モデル不在・読み込み失敗時は [available] が false になり、
/// 呼び出し側は検出失敗 (紙なし) として扱う。
class PaperNet {
  PaperNet._();

  static const int size = 256;
  static const int elements = size * size;
  static const String _assetPath = 'assets/models/paper_seg.onnx';

  static OrtSessionBundle? _bundle;
  static bool _failed = false;
  static Future<void>? _loading;

  static bool get available => !_failed && _bundle != null;

  /// ロードを試みて利用可否を返す。
  static Future<bool> ensureAvailable() async {
    await ensureLoaded();
    return available;
  }

  static Future<void> ensureLoaded() async {
    if (_bundle != null || _failed) return;
    _loading ??= _load();
    await _loading;
  }

  static Future<void> _load() async {
    try {
      await OrtApiBindings.preparePlatform();
      final bytes = (await rootBundle.load(_assetPath)).buffer.asUint8List();
      // FFI セッション生成はどの isolate でも可。ここはメイン isolate。
      _bundle = OrtApiBindings.createSessionBundle(bytes);
    } catch (e) {
      debugPrint('PaperNet: model unavailable ($e)');
      _failed = true;
    }
  }

  /// 輝度画像から紙面の四隅 (正規化座標 [TL,TR,BR,BL]) を推論する。
  /// 使えない場合・推論失敗時は null (呼び出し側は検出失敗として扱う)。
  static Future<List<Offset>?> detectQuad(Uint8List gray, int w, int h) async {
    await ensureLoaded();
    final bundle = _bundle;
    if (bundle == null || w <= 0 || h <= 0) return null;
    final sw = Stopwatch()..start();
    try {
      // 推論本体は OrtSessionBundle.detectPaperQuad (ライブ検出・評価ハーネスと共通)
      double fill = 0;
      final flat = bundle.detectPaperQuad(
        gray,
        w,
        h,
        onDebug: kDebugMode
            ? (input, mask, filled, f) {
                fill = f;
                _dumpDebug(input, mask, filled);
              }
            : null,
      );
      final quad = flat == null
          ? null
          : <Offset>[
              for (int i = 0; i < 8; i += 2) Offset(flat[i], flat[i + 1]),
            ];
      if (kDebugMode) {
        debugPrint('PaperNet: quad=$quad mask=${(fill * 100).toStringAsFixed(1)}% '
            '${sw.elapsedMilliseconds}ms');
      }
      return quad;
    } catch (e) {
      debugPrint('PaperNet: inference failed ($e)');
      return null;
    }
  }

  /// デバッグ用: 入力グレー / 穴埋めマスクのオーバーレイを保存する。
  static void _dumpDebug(
      Float32List input, Uint8List mask, Uint8List filled) {
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final grayImg = img.Image(width: size, height: size);
      final ovImg = img.Image(width: size, height: size);
      for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
          final i = y * size + x;
          final g = (input[i] * 255).round().clamp(0, 255);
          grayImg.data?.setPixelR(x, y, g);
          if (filled[i] > 0) {
            ovImg.data?.setPixelRgb(x, y, 255, 0, 0);
          } else {
            ovImg.data?.setPixelRgb(x, y, g, g, g);
          }
        }
      }
      getTemporaryDirectory().then((dir) {
        File('${dir.path}/paper_debug_${ts}_gray.png')
            .writeAsBytesSync(Uint8List.fromList(img.encodePng(grayImg)));
        File('${dir.path}/paper_debug_${ts}_overlay.png')
            .writeAsBytesSync(Uint8List.fromList(img.encodePng(ovImg)));
      });
    } catch (_) {
      // デバッグダンプは失敗しても無視
    }
  }
}

