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

  /// net 推論 → 四角形 (正規化座標の平坦リスト) or null (紙なし/形が崩壊)。
  /// 実装は切り抜き画面・評価ハーネスと共通の OrtSessionBundle.detectPaperQuad。
  List<double>? detectNet(Uint8List gray, int w, int h) {
    return netBundle!.detectPaperQuad(
      gray,
      w,
      h,
      onDebug: kDebugMode
          ? (_, _, _, fill) => debugPrint(
              'WorkerNet: mask fill=${(fill * 100).toStringAsFixed(1)}%')
          : null,
    );
  }

  /// ヒューリスティック (大津ベース)。net が読み込めなかったときだけ使う。
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
    try {
      await OrtApiBindings.preparePlatform();
    } catch (e) {
      if (kDebugMode) debugPrint('WorkerNet: ORT platform init failed: $e');
    }
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
    // net モデルを送って初期化 (iOS は ORT の入口アドレスも渡す。isolate 間で共有されないため)
    _sendPort!.send(
        <Object>['init', modelBytes, OrtApiBindings.iosApiBaseAddress ?? 0]);
  }

  /// ワーカーからのメッセージ ('ready' 応答 / 検出結果) を振り分ける。
  void _onWorkerMessage(dynamic message) {
    if (message is List && message.isNotEmpty && message[0] == 'ready') {
      netReady = message[1] as bool;
      if (kDebugMode) debugPrint('WorkerNet: main side netReady=$netReady');
      return;
    }
    // 検出結果が返った = ワーカーは次の依頼を受けられる。
    // (ここで戻さないと isBusy が true のままになり、ライブ検出が最初の
    //  1 フレームで止まる)
    _busy = false;
    final callback = _onResult;
    _onResult = null;
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
          _workerState.netBundle = OrtApiBindings.createSessionBundle(
              message[1] as Uint8List,
              apiBaseAddress: message.length > 2 ? message[2] as int : null);
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
        // net の null は「紙なし」の判定なので、ヒューリスティックで上書きしない
        // (上書きすると机の明部などを紙として枠表示・自動撮影してしまう)。
        // ヒューリスティックは net が使えない場合のみ。
        final List<double>? flat;
        if (netReady) {
          flat = _workerState.detectNet(gray, w, h);
          if (kDebugMode) {
            debugPrint('WorkerNet: net flat=${flat?.join(',') ?? 'null'}');
          }
        } else {
          flat = _workerState.detectHeuristic(gray, w, h);
          if (kDebugMode) {
            debugPrint('WorkerNet: heuristic result=${flat?.join(',') ?? 'null'}');
          }
        }
        reply?.send(flat);
      } catch (e) {
        if (kDebugMode) debugPrint('WorkerNet: detect error: $e');
        reply?.send(null);
      }
    });
  }
}
