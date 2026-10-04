import 'dart:ffi';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'ort_ffi.dart';

/// AI によるシャープ化 (Real-ESRGAN の realesr-animevideov3, BSD-3)。
///
/// x4 超解像モデルを「縮小 → x4 → 元の大きさ」で使い、ぼけ・ノイズ・紙の地模様を取って
/// 文字や音符の輪郭をくっきりさせる。モデルは入力 256x256 → 出力 1024x1024 の固定形状で、
/// 画像を重なり付きのタイルに分けて推論する (tools/sr_eval.py と同じ方式)。
/// モデルは int8 量子化済み (tools/sr_quantize.py。fp32 との差 PSNR 約 38dB、文字の見た目は同じ)。
///
/// 端末の CPU で数秒〜数十秒かかるので、必ず isolate 上で呼ぶ (ImagePipeline が呼ぶ)。
class AiSharpen {
  AiSharpen._();

  /// 線画向けの軽量版 (畳み込み 16 層)。汎用版 (realesr-general-x4v3, 32 層) より約 2 倍速く、
  /// 文字・音符の周りに白い縁取りが出ない (docs/IMAGE_RECOGNITION_RESEARCH.md の比較)。
  static const String assetPath = 'assets/models/sr_anime_x4v3_int8_t256.onnx';

  /// モデルの入力タイル (出力は 4 倍)。大きいほど重なりの無駄が減る (128 比で約 8%)。
  static const int tile = 256;
  static const int scale = 4;

  /// タイル境界の継ぎ目を消すための重なり (入力側)。
  static const int overlap = 8;

  /// 推論前に縮小する割合。2 = 半分に縮小して x4 → 2 倍の大きさから元へ縮小。
  /// 4 (1/4 → x4) は 4 倍速いが、小さく写った文字が別の字形に崩れる (実機で確認) ので使わない。
  static const int downscale = 2;

  /// 端末で使う ORT の設定。HiPad (MT6785) の実測 (int8 の 256 タイル): 標準 CPU 8 スレッド 429ms、
  /// XNNPACK は int8 だと遅い (1075ms)。fp32 は XNNPACK 8 スレッドでも 1151ms。
  /// 待ち合わせのスピンは他の処理 (カメラなど) と CPU を取り合うので止める。
  static const OrtSessionConfig sessionConfig = OrtSessionConfig(
    intraOpThreads: 8,
    configEntries: <String, String>{'session.intra_op.allow_spinning': '0'},
  );

  /// 開発用: [configs] ごとに 1 タイルあたりの推論時間 (ms、ウォームアップ後 [runs] 回の中央値)。
  /// 自己診断 (selftest/AIBENCH) から呼ぶ。
  static List<String> benchmark(
    Uint8List modelBytes,
    List<OrtSessionConfig> configs, {
    int runs = 5,
    int? apiBaseAddress,
    int tileSize = tile,
  }) {
    final lines = <String>[];
    for (final c in configs) {
      try {
        final createWatch = Stopwatch()..start();
        final bundle = OrtApiBindings.createSessionBundle(
          modelBytes,
          apiBaseAddress: apiBaseAddress,
          inputShape: <int>[1, 3, tileSize, tileSize],
          outputShape: <int>[1, 3, tileSize * scale, tileSize * scale],
          config: c,
        );
        final createMs = createWatch.elapsedMilliseconds;
        try {
          final input = bundle.inputData.asTypedList(3 * tileSize * tileSize);
          for (int i = 0; i < input.length; i++) {
            input[i] = (i % 97) / 97.0;
          }
          bundle.bindings.runSimple(bundle); // ウォームアップ
          final ms = <int>[];
          for (int r = 0; r < runs; r++) {
            final sw = Stopwatch()..start();
            bundle.bindings.runSimple(bundle);
            ms.add(sw.elapsedMilliseconds);
          }
          ms.sort();
          lines.add('$c create=${createMs}ms tile=${ms[ms.length ~/ 2]}ms');
        } finally {
          bundle.release();
        }
      } catch (e) {
        lines.add('$c ERROR $e');
      }
    }
    return lines;
  }

  /// [rgb] (幅 [w] x 高さ [h] の RGB) をシャープ化した同じ大きさの RGB を返す。
  static Uint8List process(
    Uint8List rgb,
    int w,
    int h,
    Uint8List modelBytes, {
    String? libraryPath,
    int? apiBaseAddress,
    int downscale = AiSharpen.downscale,
    OrtSessionConfig config = sessionConfig,
    void Function(int done, int total)? onProgress,
  }) {
    assert(scale % downscale == 0);
    final sw = Stopwatch()..start();
    // 縮小画像は切り上げで作り、最後に元の大きさへ切り詰める (端数で 1px 足りなくならないように)
    final sw0 = math.max(1, (w + downscale - 1) ~/ downscale);
    final sh0 = math.max(1, (h + downscale - 1) ~/ downscale);
    final small = resizeRgbArea(rgb, w, h, sw0, sh0);
    final tSmall = sw.elapsedMilliseconds;
    // x4 の出力を downscale x downscale 画素ずつ平均して書き出す (= 元の解像度)。
    // 4 倍の大きさの中間画像を作ってから縮小すると、実機でそれだけで数秒かかっていた。
    final perSmall = scale ~/ downscale; // 縮小画像 1px あたりの出力 px
    final block = downscale;
    final inv = 1.0 / (block * block);

    OrtSessionBundle open(OrtSessionConfig c) => OrtApiBindings.createSessionBundle(
          modelBytes,
          libraryPath: libraryPath,
          apiBaseAddress: apiBaseAddress,
          inputShape: const <int>[1, 3, tile, tile],
          outputShape: const <int>[1, 3, tile * scale, tile * scale],
          config: c,
        );
    OrtSessionBundle bundle;
    try {
      bundle = open(config);
    } catch (e) {
      // XNNPACK を含まない ORT (Windows のテスト用 DLL など) では標準の CPU 実行に戻す
      debugPrint('AiSharpen: $config unavailable, fallback to cpu ($e)');
      bundle = open(const OrtSessionConfig());
    }
    final tOpen = sw.elapsedMilliseconds;
    var msIn = 0, msRun = 0, msOut = 0;
    final lap = Stopwatch();
    final upW = sw0 * perSmall;
    final upH = sh0 * perSmall;
    final up = Uint8List(upW * upH * 3);
    const core = tile - 2 * overlap;
    final tilesX = (sw0 + core - 1) ~/ core;
    final tilesY = (sh0 + core - 1) ~/ core;
    final total = tilesX * tilesY;
    final input = bundle.inputData.asTypedList(3 * tile * tile);
    const outTile = tile * scale;
    final output = bundle.outputData.asTypedList(3 * outTile * outTile);
    const plane = tile * tile;
    const outPlane = outTile * outTile;
    var done = 0;
    try {
      for (int ty = 0; ty < tilesY; ty++) {
        for (int tx = 0; tx < tilesX; tx++) {
          lap
            ..reset()
            ..start();
          final x0 = tx * core - overlap;
          final y0 = ty * core - overlap;
          // 入力タイル (CHW, 0..1)。画像の外は反射で埋める
          for (int y = 0; y < tile; y++) {
            final sy = _reflect(y0 + y, sh0);
            for (int x = 0; x < tile; x++) {
              final sx = _reflect(x0 + x, sw0);
              final si = (sy * sw0 + sx) * 3;
              final di = y * tile + x;
              input[di] = small[si] / 255.0;
              input[plane + di] = small[si + 1] / 255.0;
              input[2 * plane + di] = small[si + 2] / 255.0;
            }
          }
          msIn += lap.elapsedMilliseconds;
          lap.reset();
          bundle.bindings.runSimple(bundle);
          msRun += lap.elapsedMilliseconds;
          lap.reset();
          // 重なりを除いた中央部分を、block x block の平均で縮めながら書き戻す
          final cw = math.min(core, sw0 - tx * core) * perSmall;
          final ch = math.min(core, sh0 - ty * core) * perSmall;
          final ox = tx * core * perSmall;
          final oy = ty * core * perSmall;
          const base = overlap * scale;
          for (int y = 0; y < ch; y++) {
            final row0 = (base + y * block) * outTile + base;
            var di = ((oy + y) * upW + ox) * 3;
            for (int x = 0; x < cw; x++) {
              var r = 0.0, g = 0.0, b = 0.0;
              for (int by = 0; by < block; by++) {
                var si = row0 + by * outTile + x * block;
                for (int bx = 0; bx < block; bx++) {
                  r += output[si];
                  g += output[outPlane + si];
                  b += output[2 * outPlane + si];
                  si++;
                }
              }
              up[di] = _toByte(r * inv);
              up[di + 1] = _toByte(g * inv);
              up[di + 2] = _toByte(b * inv);
              di += 3;
            }
          }
          msOut += lap.elapsedMilliseconds;
          done++;
          onProgress?.call(done, total);
        }
      }
    } finally {
      bundle.release();
    }
    // 切り上げた分の端を落として元の大きさにする (行ごとのコピーだけ)
    var out = up;
    if (upW != w || upH != h) {
      out = Uint8List(w * h * 3);
      for (int y = 0; y < h; y++) {
        out.setRange(y * w * 3, (y + 1) * w * 3, up, y * upW * 3);
      }
    }
    debugPrint('AiSharpen: ${w}x$h tiles=$total ms=${sw.elapsedMilliseconds} '
        '(small=$tSmall open=${tOpen - tSmall} in=$msIn run=$msRun out=$msOut)');
    return out;
  }

  static int _reflect(int i, int n) {
    if (n == 1) return 0;
    while (i < 0 || i >= n) {
      if (i < 0) i = -i;
      if (i >= n) i = 2 * n - 2 - i;
    }
    return i;
  }

  static int _toByte(double v) {
    final x = (v * 255.0 + 0.5).toInt();
    return x < 0 ? 0 : (x > 255 ? 255 : x);
  }
}

/// RGB 画像の縮小・拡大 (縮小は面積平均、拡大は双線形)。
@visibleForTesting
Uint8List resizeRgbArea(Uint8List src, int sw, int sh, int dw, int dh) {
  if (sw == dw && sh == dh) return Uint8List.fromList(src);
  final dst = Uint8List(dw * dh * 3);
  if (dw > sw || dh > sh) {
    // 拡大 (縮小推論の端数で 1px 足りない場合などのみ): 双線形
    for (int y = 0; y < dh; y++) {
      final fy = ((y + 0.5) * sh / dh - 0.5).clamp(0.0, sh - 1.0);
      final y0 = fy.floor();
      final y1 = math.min(y0 + 1, sh - 1);
      final wy = fy - y0;
      for (int x = 0; x < dw; x++) {
        final fx = ((x + 0.5) * sw / dw - 0.5).clamp(0.0, sw - 1.0);
        final x0 = fx.floor();
        final x1 = math.min(x0 + 1, sw - 1);
        final wx = fx - x0;
        for (int c = 0; c < 3; c++) {
          final a = src[(y0 * sw + x0) * 3 + c] * (1 - wx) + src[(y0 * sw + x1) * 3 + c] * wx;
          final b = src[(y1 * sw + x0) * 3 + c] * (1 - wx) + src[(y1 * sw + x1) * 3 + c] * wx;
          dst[(y * dw + x) * 3 + c] = (a * (1 - wy) + b * wy + 0.5).toInt();
        }
      }
    }
    return dst;
  }
  // 縮小: 出力 1 画素に対応する入力の矩形を (端数の重みを無視して) 平均する
  final sum = Int32List(3);
  for (int y = 0; y < dh; y++) {
    final ys = y * sh ~/ dh;
    final ye = math.max(ys + 1, (y + 1) * sh ~/ dh);
    for (int x = 0; x < dw; x++) {
      final xs = x * sw ~/ dw;
      final xe = math.max(xs + 1, (x + 1) * sw ~/ dw);
      sum[0] = 0;
      sum[1] = 0;
      sum[2] = 0;
      for (int yy = ys; yy < ye; yy++) {
        var si = (yy * sw + xs) * 3;
        for (int xx = xs; xx < xe; xx++) {
          sum[0] += src[si];
          sum[1] += src[si + 1];
          sum[2] += src[si + 2];
          si += 3;
        }
      }
      final n = (ye - ys) * (xe - xs);
      final di = (y * dw + x) * 3;
      dst[di] = (sum[0] + n ~/ 2) ~/ n;
      dst[di + 1] = (sum[1] + n ~/ 2) ~/ n;
      dst[di + 2] = (sum[2] + n ~/ 2) ~/ n;
    }
  }
  return dst;
}
