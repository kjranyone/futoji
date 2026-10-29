import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import 'detector.dart';
import 'ort_ffi.dart';

/// CameraImage を [decimate] 画素おきに間引いた画素列にする。
/// 戻り値: (画素列, 実効幅, 実効高, 1 画素のバイト数)。
/// YUV420 (Android の 3 平面、iOS の 2 平面) と BGRA は RGB (3)、
/// それ以外は Y 平面の灰色 (1)。色は紙と机 (明るさが近いベージュなど) の見分けに使う。
(Uint8List, int, int, int) extractFramePixels(CameraImage image, {int decimate = 2}) {
  final d = decimate < 1 ? 1 : decimate;
  final planes = image.planes;
  final group = image.format.group;
  if (group == ImageFormatGroup.yuv420 && planes.length >= 2) {
    return _yuvToRgb(image, d);
  }
  if (group == ImageFormatGroup.bgra8888 && planes.isNotEmpty) {
    return _bgraToRgb(image, d);
  }
  final (gray, dw, dh) = _grayPlane(image, d);
  return (gray, dw, dh, 1);
}

(Uint8List, int, int) _grayPlane(CameraImage image, int d) {
  final plane = image.planes.first;
  final bytes = plane.bytes;
  final w = image.width;
  final h = image.height;
  final rowStride = plane.bytesPerRow;
  final pixelStride = plane.bytesPerPixel ?? 1;
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

/// YUV420 (色差は縦横 1/2) → RGB (BT.601)。
/// Android の 3 平面 (YUV_420_888) はフルレンジ (JPEG と同じ)。
/// 2 平面 (iOS の 420YpCbCr8BiPlanarVideoRange) はビデオレンジ (Y 16〜235) で、
/// 2 枚目に Cb, Cr が交互に並ぶ。
(Uint8List, int, int, int) _yuvToRgb(CameraImage image, int d) {
  final yp = image.planes[0];
  final up = image.planes[1];
  final twoPlanes = image.planes.length == 2;
  final vp = twoPlanes ? up : image.planes[2];
  final vOffset = twoPlanes ? 1 : 0;
  final yBytes = yp.bytes, uBytes = up.bytes, vBytes = vp.bytes;
  final yRow = yp.bytesPerRow, yPix = yp.bytesPerPixel ?? 1;
  final uRow = up.bytesPerRow, uPix = up.bytesPerPixel ?? (twoPlanes ? 2 : 1);
  final vRow = vp.bytesPerRow, vPix = vp.bytesPerPixel ?? (twoPlanes ? 2 : 1);
  final dw = image.width ~/ d;
  final dh = image.height ~/ d;
  final out = Uint8List(dw * dh * 3);
  int clamp(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
  // ビデオレンジをフルレンジに広げる係数
  final ys = twoPlanes ? 255 / 219 : 1.0;
  final y0 = twoPlanes ? 16 : 0;
  final cs = twoPlanes ? 255 / 224 : 1.0;
  var o = 0;
  for (int y = 0; y < dh; y++) {
    final sy = y * d;
    final cy = sy >> 1;
    for (int x = 0; x < dw; x++) {
      final sx = x * d;
      final cx = sx >> 1;
      final yy = (yBytes[sy * yRow + sx * yPix] - y0) * ys;
      // 平面の末尾は行の途中で切れていることがあるので範囲内に収める
      final ui = cy * uRow + cx * uPix;
      final vi = cy * vRow + cx * vPix + vOffset;
      final u = (uBytes[ui < uBytes.length ? ui : uBytes.length - 1] - 128) * cs;
      final v = (vBytes[vi < vBytes.length ? vi : vBytes.length - 1] - 128) * cs;
      out[o++] = clamp(yy + 1.402 * v);
      out[o++] = clamp(yy - 0.344136 * u - 0.714136 * v);
      out[o++] = clamp(yy + 1.772 * u);
    }
  }
  return (out, dw, dh, 3);
}

(Uint8List, int, int, int) _bgraToRgb(CameraImage image, int d) {
  final p = image.planes[0];
  final bytes = p.bytes;
  final row = p.bytesPerRow;
  final dw = image.width ~/ d;
  final dh = image.height ~/ d;
  final out = Uint8List(dw * dh * 3);
  var o = 0;
  for (int y = 0; y < dh; y++) {
    final base = y * d * row;
    for (int x = 0; x < dw; x++) {
      final i = base + x * d * 4;
      out[o++] = bytes[i + 2];
      out[o++] = bytes[i + 1];
      out[o++] = bytes[i];
    }
  }
  return (out, dw, dh, 3);
}

/// ワーカー isolate 内の検出状態 (net セッション)。
final _WorkerState _workerState = _WorkerState();

class _WorkerState {
  OrtSessionBundle? netBundle;

  /// net 推論 → 四角形 (正規化座標の平坦リスト) or null (紙なし/形が崩壊)。
  /// 実装は切り抜き画面・評価ハーネスと共通の OrtSessionBundle.detectPaperQuad。
  List<double>? detectNet(Uint8List pixels, int w, int h, int channels) {
    return netBundle!.detectPaperQuad(
      pixels,
      w,
      h,
      channels: channels,
      onDebug: kDebugMode
          ? (_, _, _, fill) => debugPrint(
              'WorkerNet: mask fill=${(fill * 100).toStringAsFixed(1)}%')
          : null,
    );
  }

  /// ヒューリスティック (大津ベース)。net が読み込めなかったときだけ使う。
  List<double>? detectHeuristic(Uint8List pixels, int w, int h, int channels) {
    final quad = DocumentDetector.detectLuminance(
        DocumentDetector.lumaOf(pixels, channels), w, h);
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
/// メイン isolate はフレームの間引き (と色の変換) だけ行い、重い検出はワーカー側で回す。
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
  /// [pixels] は 1 画素 [channels] バイト (1: 灰色、3: RGB、4: RGBA) の画素列。
  bool submit(
    Uint8List pixels,
    int width,
    int height,
    void Function(List<Offset>? corners) onResult, {
    int channels = 1,
  }) {
    if (_busy || _sendPort == null) return false;
    _busy = true;
    _onResult = onResult;
    _sendPort!.send(<Object>[pixels, width, height, channels]);
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
          _workerState.netBundle = OrtApiBindings.createPaperSessionBundle(
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
      final pixels = args[0] as Uint8List;
      final w = args[1] as int;
      final h = args[2] as int;
      final channels = args[3] as int;
      try {
        // net の null は「紙なし」の判定なので、ヒューリスティックで上書きしない
        // (上書きすると机の明部などを紙として枠表示・自動撮影してしまう)。
        // ヒューリスティックは net が使えない場合のみ。
        final List<double>? flat;
        if (netReady) {
          flat = _workerState.detectNet(pixels, w, h, channels);
          if (kDebugMode) {
            debugPrint('WorkerNet: net flat=${flat?.join(',') ?? 'null'}');
          }
        } else {
          flat = _workerState.detectHeuristic(pixels, w, h, channels);
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
