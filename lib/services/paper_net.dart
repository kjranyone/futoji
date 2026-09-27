import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;

import 'ort_ffi.dart';
import 'detector.dart';

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
      // 入力を書き込み (バイリニア縮小 + 0..1 正規化)
      final input = bundle.inputData.asTypedList(elements);
      final scaleX = w / size;
      final scaleY = h / size;
      for (int y = 0; y < size; y++) {
        final sy = (y + 0.5) * scaleY - 0.5;
        final y0 = sy.floor().clamp(0, h - 1);
        final y1 = (y0 + 1).clamp(0, h - 1);
        final fy = (sy - y0).clamp(0.0, 1.0);
        final row0 = y0 * w;
        final row1 = y1 * w;
        for (int x = 0; x < size; x++) {
          final sx = (x + 0.5) * scaleX - 0.5;
          final x0 = sx.floor().clamp(0, w - 1);
          final x1 = (x0 + 1).clamp(0, w - 1);
          final fx = (sx - x0).clamp(0.0, 1.0);
          final p00 = gray[row0 + x0].toDouble();
          final p10 = gray[row0 + x1].toDouble();
          final p01 = gray[row1 + x0].toDouble();
          final p11 = gray[row1 + x1].toDouble();
          final top = p00 + (p10 - p00) * fx;
          final bottom = p01 + (p11 - p01) * fx;
          input[y * size + x] =
              ((top + (bottom - top) * fy) / 255.0).clamp(0.0, 1.0);
        }
      }

      bundle.bindings.runSimple(bundle);

      // ロジット → 2値マスク (0/255)
      final output = bundle.outputData.asTypedList(elements);
      final mask = Uint8List(elements);
      int maskSum = 0;
      for (int i = 0; i < elements; i++) {
        if (output[i] > 0) {
          mask[i] = 255;
          maskSum++;
        }
      }
      // ほぼ空 / ほぼ全部のマスクは紙なし扱い
      if (maskSum < elements * 0.02 || maskSum > elements * 0.99) {
        if (kDebugMode) {
          debugPrint(
              'PaperNet: no paper mask (${(maskSum / elements * 100).toStringAsFixed(1)}%) ${sw.elapsedMilliseconds}ms');
        }
        return null;
      }

      // 文字・譜線で開いた穴を埋めてから四角形を推定する
      final filled = DocumentDetector.fillHoles(mask, size, size);
      final quad = DocumentDetector.detectLuminance(
          filled, size, size,
          workWidth: size, paperChecks: false);
      if (kDebugMode) {
        debugPrint('PaperNet: quad=$quad mask=${(maskSum / elements * 100).toStringAsFixed(1)}% '
            '${sw.elapsedMilliseconds}ms');
        _dumpDebug(input, mask, filled);
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
          if (filled[i] == 1) {
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

