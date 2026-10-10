import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;

import 'ai_sharpen.dart';
import 'db_service.dart';
import 'detection_worker.dart';
import 'detector.dart';
import 'fast_decode.dart';
import 'image_pipeline.dart';
import 'ort_ffi.dart';
import 'paper_net.dart';
import 'quad_label.dart';
import 'storage.dart';
import 'training_capture.dart';

/// 実機での紙面検出の自己診断 (開発用)。
///
/// 端末のアプリ外部領域に `selftest/RUN` がある場合だけ起動時に 1 回実行する
/// (通常の利用では何もしない)。`./dev.ps1 selftest` が画像と目印を置いて起動し、
/// 結果 (logcat の `FUTOJI_SELFTEST` 行と selftest/result.json) を回収する。
///
/// 検証する経路:
/// - crop: 切り抜き画面と同じ (正立 → 長辺 1000px → 輝度 → PaperNet.detectQuad, メイン isolate)
/// - worker: ライブ検出と同じ常駐ワーカー isolate (DetectionWorker)
/// `<id>.json` (QuadLabel) があれば角誤差も計算し、PC の評価ハーネスと突き合わせられる。
class SelfTest {
  SelfTest._();

  static const String tag = 'FUTOJI_SELFTEST';
  static const String _lastTokenKey = 'selftest_last_token';
  static const String _enabledKey = 'selftest_enabled';

  /// 設定画面の「紙面検出の自己診断を許可」。OFF (既定) なら目印があっても何もしない。
  static bool get enabled =>
      DbService.settings.get(_enabledKey, defaultValue: false) as bool;

  static Future<void> setEnabled(bool value) =>
      DbService.settings.put(_enabledKey, value);

  static void _log(String message) => debugPrint('$tag $message');

  static Future<void> runIfRequested() async {
    if (!enabled) return;
    try {
      final base = (await TrainingCapture.directory()).parent;
      final dir = Directory('${base.path}${Platform.pathSeparator}selftest');
      final marker = File('${dir.path}${Platform.pathSeparator}RUN');
      if (!await marker.exists()) return;
      // 目印には dev.ps1 が毎回違うトークンを書く。削除に失敗して目印が残っても
      // 同じトークンでは二度と実行しない (通常起動のたびに走るのを防ぐ)。
      final token = (await marker.readAsString()).trim();
      await marker.delete();
      final last = DbService.settings.get(_lastTokenKey) as String?;
      if (token.isEmpty || token == last) {
        _log('SKIP token=${token.isEmpty ? '(empty)' : token} (実行済み)');
        return;
      }
      await DbService.settings.put(_lastTokenKey, token);
      // AIBENCH があれば AI シャープ化の速度比較だけを行う (ORT の設定を端末で決めるため)
      final bench = File('${dir.path}${Platform.pathSeparator}AIBENCH');
      if (await bench.exists()) {
        await bench.delete();
        await _aiBench(dir);
        return;
      }
      await _run(dir);
    } catch (e, st) {
      _log('ERROR $e\n$st');
    }
  }

  /// AI シャープ化の 1 タイルあたりの時間を ORT の設定ごとに測る。
  /// 同梱モデルに加え、selftest/ に置いた sr_*.onnx (別モデルの候補) も測る。
  static Future<void> _aiBench(Directory dir) async {
    _log('AIBENCH START');
    await OrtApiBindings.preparePlatform();
    final apiBase = OrtApiBindings.iosApiBaseAddress;
    final models = <String, Uint8List>{
      'bundled': (await rootBundle.load(AiSharpen.assetPath)).buffer.asUint8List(),
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.onnx'))
          f.uri.pathSegments.last: f.readAsBytesSync(),
    };
    const spin = <String, String>{'session.intra_op.allow_spinning': '0'};
    const configs = <OrtSessionConfig>[
      OrtSessionConfig(),
      OrtSessionConfig(intraOpThreads: 4),
      OrtSessionConfig(intraOpThreads: 8),
      OrtSessionConfig(
          intraOpThreads: 1,
          executionProvider: 'XNNPACK',
          providerOptions: <String, String>{'intra_op_num_threads': '4'},
          configEntries: spin),
      OrtSessionConfig(
          intraOpThreads: 1,
          executionProvider: 'XNNPACK',
          providerOptions: <String, String>{'intra_op_num_threads': '8'},
          configEntries: spin),
    ];
    for (final m in models.entries) {
      // ファイル名の _t256 などがタイルの大きさ (無ければ 128)
      final t = int.tryParse(
              RegExp(r'_t(\d+)').firstMatch(m.key)?.group(1) ?? '') ??
          AiSharpen.tile;
      final lines = await _benchInIsolate(m.value, configs, apiBase, t);
      for (final l in lines) {
        _log('AIBENCH ${m.key} $l');
      }
    }
    _log('DONE');
  }

  static Future<List<String>> _benchInIsolate(Uint8List model,
          List<OrtSessionConfig> configs, int? apiBase, int tileSize) =>
      Isolate.run(() => AiSharpen.benchmark(model, configs,
          apiBaseAddress: apiBase, tileSize: tileSize));

  /// クロージャがこの関数の変数 (DetectionWorker など送れない物) を拾わないよう分ける。
  static Future<Uint8List> _grayInIsolate(img.Image im) =>
      Isolate.run(() => DocumentDetector.toGray(im));

  static Future<void> _run(Directory dir) async {
    _log('START ${dir.path}');
    final loadWatch = Stopwatch()..start();
    final ok = await PaperNet.ensureAvailable();
    _log('model_loaded=$ok load_ms=${loadWatch.elapsedMilliseconds}');

    final worker = DetectionWorker();
    final modelBytes =
        (await rootBundle.load('assets/models/paper_seg.onnx')).buffer.asUint8List();
    await worker.start(modelBytes);

    final images = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jpg'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final results = <Map<String, Object?>>[];
    for (final f in images) {
      final id = f.uri.pathSegments.last.replaceAll('.jpg', '');
      final bytes = await f.readAsBytes();
      final decodeWatch = Stopwatch()..start();
      final work = await decodeWorkImage(bytes); // 切り抜き画面と同じ
      final decodeMs = decodeWatch.elapsedMilliseconds;
      final gray = await _grayInIsolate(work);
      final w = work.width;
      final h = work.height;

      final cropWatch = Stopwatch()..start();
      final crop = await PaperNet.detectQuad(gray, w, h);
      final cropMs = cropWatch.elapsedMilliseconds;

      final workerWatch = Stopwatch()..start();
      final completer = Completer<List<Offset>?>();
      // 前の依頼が処理中なら空くまで待つ (空かなければワーカー不具合として記録)
      var accepted = false;
      for (int i = 0; i < 500 && !accepted; i++) {
        accepted = worker.submit(gray, w, h, completer.complete);
        if (!accepted) await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      List<Offset>? live;
      String? workerError;
      if (!accepted) {
        workerError = 'worker stayed busy';
      } else {
        try {
          live = await completer.future.timeout(const Duration(seconds: 15));
        } on TimeoutException {
          workerError = 'worker timeout';
        }
      }
      final workerMs = workerWatch.elapsedMilliseconds;

      // 保存処理 (撮影 1 枚ごとに走る) の所要時間。一時ページとして保存してすぐ消す。
      final saveWatch = Stopwatch()..start();
      String? saveError;
      final tmpPageId = 'selftest_$id';
      final saveTimings = <String, int>{};
      try {
        final scan = await ImagePipeline.processAndSave(
          rawFile: f,
          cornersNormalized: crop ?? _fullFrame,
          rotationDeg: 0,
          pageId: tmpPageId,
          // アプリの既定 (曲がり補正 ON) と同じ経路で測る
          dewarp: true,
          timings: saveTimings,
        );
        if (crop != null) {
          // 紙ありは保存結果を目視確認できるよう残す (dev.ps1 selftest が回収)
          await scan.imageFile
              .copy('${dir.path}${Platform.pathSeparator}saved_$id.webp');
        }
        await scan.imageFile.delete();
        await scan.thumbFile.delete();
      } catch (e) {
        saveError = '$e';
        await AppPaths.deletePageFiles(tmpPageId);
      }
      final saveMs = saveWatch.elapsedMilliseconds;

      final entry = <String, Object?>{
        'id': id,
        'width': w,
        'height': h,
        'decode_ms': decodeMs,
        'crop': _flat(crop),
        'crop_ms': cropMs,
        'worker': _flat(live),
        'worker_ms': workerMs,
        'worker_error': ?workerError,
        'save_ms': saveMs,
        'save_timings': saveTimings,
        'save_error': ?saveError,
      };
      final labelFile = File('${dir.path}${Platform.pathSeparator}$id.json');
      if (await labelFile.exists()) {
        final label = QuadLabel.fromJson(
            (jsonDecode(await labelFile.readAsString()) as Map)
                .cast<String, Object?>());
        final truth = label.corners;
        entry['negative'] = truth == null;
        if (truth != null && crop != null) {
          entry['crop_err'] = QuadMetrics.cornerError(crop, truth, w, h).mean;
        }
        if (truth != null && live != null) {
          entry['worker_err'] = QuadMetrics.cornerError(live, truth, w, h).mean;
        }
      }
      results.add(entry);
      _log('RESULT ${jsonEncode(entry)}');
    }
    worker.dispose();

    await File('${dir.path}${Platform.pathSeparator}result.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'model_loaded': ok,
      'results': results,
    }));
    _log('DONE n=${results.length}');
  }

  static const List<Offset> _fullFrame = <Offset>[
    Offset(0.05, 0.05),
    Offset(0.95, 0.05),
    Offset(0.95, 0.95),
    Offset(0.05, 0.95),
  ];

  static List<double>? _flat(List<Offset>? q) =>
      q == null ? null : <double>[for (final p in q) ...<double>[p.dx, p.dy]];
}
