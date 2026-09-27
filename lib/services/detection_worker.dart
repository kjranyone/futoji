import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import 'detector.dart';
import 'ort_ffi.dart';

/// CameraImage の Y 平面を間引き gray 配列へ変換する。
/// 戻り値: (gray, 実効幅, 実効高)。
(Uint8List, int, int) extractGrayPlane(CameraImage image, {int decimate = 2}) {
  final plane = image.planes.first;
  final bytes = plane.bytes;
  final w = image.width;
  final h = image.height;
  final rowStride = plane.bytesPerRow;
  final pixelStride = plane.bytesPerPixel ?? 1;
  final d = decimate < 1 ? 1 : decimate;
  final dw = w ~/ d;
  final dh = h ~/ d;
  final out = Uint8List(dw * dh);
  for (int y = 0; y < dh; y++) {
    final srcRow = y * d * rowStride;
    final dstRow = y * dw;
    for (int x = 0; x < dw; x++) {
      out[dstRow + x] = bytes[srcRow + x * d * pixelStride];
    }
  }
  return (out, dw, dh);
}

/// ワーカー isolate 内の検出状態 (net セッション)。
final _WorkerState _workerState = _WorkerState();

class _WorkerState {
  OrtSessionBundle? netBundle;

  /// net 推論 → fillHoles → 四角形 (正規化座標) or null (紙なし/形が崩壊)。
  List<double>? detectNet(Uint8List gray, int w, int h) {
    final scaleX = w / 256;
    final scaleY = h / 256;
    for (int y = 0; y < 256; y++) {
      final sy = (y + 0.5) * scaleY - 0.5;
      final y0 = sy.floor().clamp(0, h - 1);
      final y1 = (y0 + 1).clamp(0, h - 1);
      final fy = (sy - y0).clamp(0.0, 1.0);
      final row0 = y0 * w;
      final row1 = y1 * w;
      for (int x = 0; x < 256; x++) {
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
        netBundle!
            .writeInputValue(y * 256 + x,
                ((top + (bottom - top) * fy) / 255.0).clamp(0.0, 1.0));
      }
    }
    netBundle!.bindings.runSimple(netBundle!);

    var maskSum = 0;
    final mask = Uint8List(256 * 256);
    for (int i = 0; i < 256 * 256; i++) {
      if (netBundle!.readOutputValue(i) > 0) {
        mask[i] = 255;
        maskSum++;
      }
    }
    if (kDebugMode) {
      debugPrint(
          'WorkerNet: mask fill=${(maskSum / (256 * 256) * 100).toStringAsFixed(1)}%');
    }
    if (maskSum < 256 * 256 * 0.02 || maskSum > 256 * 256 * 0.99) {
      return null; // 紙なし
    }
    final filled = DocumentDetector.fillHoles(mask, 256, 256);
    final quad = DocumentDetector.detectLuminance(
        filled, 256, 256,
        workWidth: 256, paperChecks: false);
    if (quad == null) return null;
    return <double>[
      for (final c in quad) ...<double>[c.dx, c.dy],
    ];
  }

  /// ヒューリスティックフォールバック (大津ベース)。
  List<double>? detectHeuristic(Uint8List gray, int w, int h) {
    final quad = DocumentDetector.detectLuminance(gray, w, h);
    if (quad == null) return null;
    return <double>[
      for (final c in quad) ...<double>[c.dx, c.dy],
    ];
  }
}

/// カメラ画像ストリームから紙面四隅を常駐 isolate で検出するワーカー。
///
/// ワーカー内で net (ONNX) をロードし、使えない場合は
/// ヒューリスティック (大津ベース) にフォールバックする。
/// メイン isolate は Y 平面の抽出だけ行い、重い検出はワーカー側で回す。
/// 処理中に届いたフレームはスキップする (常に最新優先ではない簡略方式)。
class DetectionWorker {
  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _replyPort;
  bool _busy = false;
  bool _started = false;

  /// ワーカーで net が使える状態か (デバッグ表示用)。
  bool netReady = false;

  void Function(List<Offset>? corners)? _onResult;

  bool get isBusy => _busy;

  Future<void> start(Uint8List modelBytes) async {
    if (_started) return;
    _started = true;
    final replyPort = ReceivePort();
    _replyPort = replyPort;
    final handshake = ReceivePort();
    final isolate = await Isolate.spawn(_workerEntry, handshake.sendPort);
    _isolate = isolate;
    final sendPort = await handshake.first as SendPort;
    handshake.close();
    if (!_started || _replyPort != replyPort) {
      // 起動中に dispose された: 生成した isolate をここで確実に止める
      isolate.kill(priority: Isolate.immediate);
      replyPort.close();
      if (identical(_isolate, isolate)) _isolate = null;
      return;
    }
    _sendPort = sendPort;
    _sendPort!.send(_replyPort!.sendPort);
    // リプライの常設ディスパッチ: 'ready' 応答と検出結果の両方を受ける
    _replyPort!.listen(_onWorkerMessage);
    // net モデルを送って初期化
    _sendPort!.send(<Object>['init', modelBytes]);
  }

  /// ワーカーからのメッセージ ('ready' 応答 / 検出結果) を振り分ける。
  void _onWorkerMessage(dynamic message) {
    if (message is List && message.isNotEmpty && message[0] == 'ready') {
      netReady = message[1] as bool;
      if (kDebugMode) debugPrint('WorkerNet: main side netReady=$netReady');
      return;
    }
    final callback = _onResult;
    if (callback == null) return;
    if (message == null) {
      callback(null);
      return;
    }
    if (message is List && message.length >= 8) {
      final flat = message.cast<num>();
      final corners = <Offset>[
        for (int i = 0; i < 8; i += 2)
          Offset(flat[i].toDouble(), flat[i + 1].toDouble()),
      ];
      callback(corners);
      return;
    }
    callback(null);
  }

  /// 検出を依頼する。ビジー中は捨てる (戻り値で判別)。
  bool submit(
    Uint8List gray,
    int width,
    int height,
    void Function(List<Offset>? corners) onResult,
  ) {
    if (_busy || _sendPort == null) return false;
    _busy = true;
    _onResult = onResult;
    _sendPort!.send(<Object>[gray, width, height]);
    return true;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _replyPort?.close();
    _isolate = null;
    _sendPort = null;
    _replyPort = null;
    _started = false;
    _busy = false;
  }

  /// ワーカー isolate のエントリ (top-level なので this を送らない)。
  static void _workerEntry(SendPort out) {
    final port = ReceivePort();
    out.send(port.sendPort);
    SendPort? reply;
    var netReady = false;
    port.listen((message) {
      if (message is SendPort) {
        reply = message;
        return;
      }
      if (message is List && message.isNotEmpty && message[0] == 'init') {
        try {
          _workerState.netBundle =
              OrtApiBindings.createSessionBundle(message[1] as Uint8List);
          netReady = true;
        } catch (e) {
          netReady = false;
          if (kDebugMode) debugPrint('WorkerNet: init failed: $e');
        }
        if (kDebugMode) debugPrint('WorkerNet: ready=$netReady');
        reply?.send(<Object>['ready', netReady]);
        return;
      }
      final args = message as List;
      final gray = args[0] as Uint8List;
      final w = args[1] as int;
      final h = args[2] as int;
      try {
        List<double>? flat;
        if (netReady) {
          flat = _workerState.detectNet(gray, w, h);
          if (kDebugMode) {
            debugPrint('WorkerNet: net flat=${flat?.join(',') ?? 'null'}');
          }
        }
        flat ??= _workerState.detectHeuristic(gray, w, h);
        if (kDebugMode && !netReady) {
          debugPrint('WorkerNet: heuristic result=${flat?.join(',') ?? 'null'}');
        }
        reply?.send(flat);
      } catch (e) {
        if (kDebugMode) debugPrint('WorkerNet: detect error: $e');
        reply?.send(null);
      }
    });
  }
}
