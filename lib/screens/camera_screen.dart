import 'dart:io';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/crop_result.dart';
import '../models/music_document.dart';
import '../services/auto_capture.dart';
import '../services/detection_worker.dart';
import '../services/detector.dart';
import '../services/fast_decode.dart';
import '../services/paper_net.dart';
import '../state/app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/edge_swipe_back.dart';
import 'crop_screen.dart';

/// 読み取り画面。
///
/// - プレビュー中も常駐 isolate で紙面四隅をリアルタイム検出しオーバーレイ表示
/// - 自動撮影モード: 紙面が安定したら自動シャッター → 切り抜きをスキップして直接保存
/// - 手動シャッターは従来通り切り抜き画面で調整して保存
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.document});

  final MusicDocument document;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? _controller;
  List<CameraDescription> _cameras = const <CameraDescription>[];
  int _cameraIndex = 0;
  int _sensorOrientation = 90;
  bool _frontCamera = false;
  FlashMode _flash = FlashMode.off;

  bool _permissionDenied = false;
  bool _starting = false;
  bool _busy = false; // 撮影〜保存中
  String? _error;

  // ---- ライブ検出 ----
  final DetectionWorker _worker = DetectionWorker();
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _liveFrameW = 0;
  int _liveFrameH = 0;
  double _previewBoxAspect = 0;

  /// オーバーレイ表示 (プレビュー正規化座標 + 色)
  final ValueNotifier<LiveOverlay> _live =
      ValueNotifier<LiveOverlay>(const LiveOverlay());

  // ---- 自動撮影 ----
  bool _autoMode = false;
  final AutoCaptureController _auto = AutoCaptureController();

  /// 自動撮影のカウントダウンの進み (0..1、カウントダウン中でなければ null)。
  /// 検出結果は 0.2 秒おき程度なので、表示はフレームごとの Ticker で滑らかに進める。
  final ValueNotifier<double?> _countdown = ValueNotifier<double?>(null);
  late final Ticker _countdownTicker = createTicker(_onCountdownTick);
  int _lastCountdownNumber = 0;

  void _onCountdownTick(Duration _) {
    final started = _auto.countdownStartedAt;
    if (!_autoMode || _busy || started == null) {
      _countdown.value = null;
      _lastCountdownNumber = 0;
      _countdownTicker.stop();
      return;
    }
    final p = (DateTime.now().difference(started).inMilliseconds / _auto.countdownMs)
        .clamp(0.0, 1.0);
    _countdown.value = p;
    final n = countdownNumber(p);
    if (n != _lastCountdownNumber) {
      _lastCountdownNumber = n;
      HapticFeedback.selectionClick();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // ライブ枠の座標変換 (frameToPreview) は縦向きを前提にしているため、
    // カメラ画面の間だけ縦向きに固定する (横持ちでは枠が 90/180 度ずれる)。
    SystemChrome.setPreferredOrientations(
        const <DeviceOrientation>[DeviceOrientation.portraitUp]);
    _loadNetAndStartWorker();
    _bootstrap();
  }

  /// net モデル (アセット) を読み込みワーカーを起動する。
  Future<void> _loadNetAndStartWorker() async {
    try {
      final bytes = (await rootBundle.load('assets/models/paper_seg.onnx'))
          .buffer
          .asUint8List();
      await _worker.start(bytes);
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('PaperNet worker start failed: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 他の画面は向き自由に戻す (空リスト = アプリ既定)
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    _controller?.dispose();
    _worker.dispose();
    _live.dispose();
    _countdownTicker.dispose();
    _countdown.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return;
      controller.dispose();
      _controller = null;
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      // inactive で破棄済み (= null) なので、ここでは null のときに再起動する
      if (_controller != null || _cameras.isEmpty || _permissionDenied) return;
      _startController(_cameraIndex);
    }
  }

  Future<void> _bootstrap() async {
    final status = await Permission.camera.request();
    if (status.isDenied || status.isPermanentlyDenied) {
      if (mounted) setState(() => _permissionDenied = true);
      return;
    }
    try {
      _cameras = await availableCameras();
    } catch (e) {
      if (mounted) setState(() => _error = 'カメラを取得できませんでした: $e');
      return;
    }
    if (_cameras.isEmpty) {
      if (mounted) setState(() => _error = '利用できるカメラがありません');
      return;
    }
    // 背面カメラを優先
    int index = 0;
    for (int i = 0; i < _cameras.length; i++) {
      if (_cameras[i].lensDirection == CameraLensDirection.back) {
        index = i;
        break;
      }
    }
    if (mounted) setState(() => _cameraIndex = index);
    await _startController(index);
  }

  Future<void> _startController(int index) async {
    if (_starting) return;
    _starting = true;
    final old = _controller;
    _controller = null;
    if (mounted) setState(() {});
    await old?.dispose();

    try {
      final controller = CameraController(
        _cameras[index],
        ResolutionPreset.max,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
      await controller.setFlashMode(_flash);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _error = null;
        _sensorOrientation = _cameras[index].sensorOrientation;
        _frontCamera =
            _cameras[index].lensDirection == CameraLensDirection.front;
      });
      await _startImageStream(controller);
    } catch (e) {
      if (mounted) setState(() => _error = 'カメラを起動できませんでした: $e');
    } finally {
      _starting = false;
    }
  }

  Future<void> _startImageStream(CameraController controller) async {
    try {
      await controller.startImageStream(_onCameraFrame);
    } catch (_) {
      // すでにストリーミング中などは無視 (ライブ検出だけの機能なので致命的ではない)
    }
  }

  /// 画像ストリーム: Y 平面を抽出しワーカーへ依頼 (約 150ms 間隔)。
  void _onCameraFrame(CameraImage image) {
    final now = DateTime.now();
    if (now.difference(_lastFrameAt).inMilliseconds < 150) return;
    _lastFrameAt = now;
    if (_busy || _worker.isBusy) return;
    if (_liveFrameW != image.width) {
      _liveFrameW = image.width;
      _liveFrameH = image.height;
    }
    final decimate = image.width >= 1280 ? 4 : 2;
    final (gray, dw, dh) = extractGrayPlane(image, decimate: decimate);
    _worker.submit(gray, dw, dh, _onLiveResult);
  }

  void _onLiveResult(List<Offset>? corners) {
    if (!mounted) return;
    List<Offset>? mapped;
    if (corners != null && _previewBoxAspect > 0) {
      mapped = <Offset>[
        for (final c in corners)
          frameToPreview(
              c, _liveFrameW, _liveFrameH, _sensorOrientation, _previewBoxAspect,
              mirror: _frontCamera),
      ];
    }
    if (_autoMode && !_busy) {
      final fire = _auto.feed(mapped, DateTime.now());
      if (_auto.paused) {
        _pauseAutoForRepeats();
      } else if (fire) {
        HapticFeedback.mediumImpact();
        _capture(auto: true);
      } else if (_auto.countdownStartedAt != null && !_countdownTicker.isActive) {
        _countdownTicker.start();
      }
    }
    // 枠の色: 探索中は白、カウントダウン中は緑、撮影済み (入れ替え待ち) は青
    var phase = LivePhase.searching;
    if (_autoMode && mapped != null) {
      if (!_auto.isArmed) {
        phase = LivePhase.captured;
      } else if (_auto.countdownStartedAt != null) {
        phase = LivePhase.countdown;
      }
    }
    final phaseChanged = phase != _live.value.phase;
    _live.value = LiveOverlay(corners: mapped, phase: phase);
    if (phaseChanged && mounted) setState(() {}); // 下部の案内文を状態に合わせる
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    final next = (_cameraIndex + 1) % _cameras.length;
    setState(() => _cameraIndex = next);
    await _startController(next);
  }

  Future<void> _toggleFlash() async {
    final next = _flash == FlashMode.off ? FlashMode.auto : FlashMode.off;
    setState(() => _flash = next);
    try {
      await _controller?.setFlashMode(next);
    } catch (_) {}
  }

  /// 紙が一度も外れないまま撮影が続いた (同じ紙を撮り続けている可能性) → 自動撮影を止める。
  void _pauseAutoForRepeats() {
    setState(() => _autoMode = false);
    _auto.reset();
    _live.value = LiveOverlay(corners: _live.value.corners);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: const Text('同じ紙を続けて撮影しそうなので、自動撮影を止めました。'
            '次の紙に入れ替えてから再開してください'),
        action: SnackBarAction(label: '再開', onPressed: _toggleAutoMode),
      ));
  }

  void _toggleAutoMode() {
    setState(() {
      _autoMode = !_autoMode;
      _auto.reset();
    });
    _live.value = LiveOverlay(corners: _live.value.corners);
    if (_autoMode) {
      showSnackBar(context, '自動撮影モード: 紙をかざすと自動で取り込みます');
    }
  }

  Future<void> _toggleAiSharpen() async {
    final app = context.read<AppState>();
    await app.setAiSharpen(!app.aiSharpen);
    if (!mounted) return;
    showSnackBar(
      context,
      app.aiSharpen
          ? 'AI でくっきりオン: 保存のたびに 10 秒ほど仕上げます'
          : 'AI でくっきりオフ: すぐに保存します',
    );
  }

  Future<void> _toggleDewarp() async {
    final app = context.read<AppState>();
    await app.setDewarp(!app.dewarp);
    if (!mounted) return;
    showSnackBar(
      context,
      app.dewarp
          ? '曲がり補正オン: 五線を手がかりに紙面の反りをまっすぐにします'
          : '曲がり補正オフ: 台形補正だけで保存します',
    );
  }

  /// ページを保存する。AI 仕上げが ON のときは、その間カメラのプレビューと
  /// フレーム配信を止めて CPU を空ける (止めないと推論が実機で約 2 倍遅くなった)。
  Future<void> _savePage(AppState app, String rawPath, CropResult crop) async {
    final controller = _controller;
    final pause = app.aiSharpen && controller != null && controller.value.isInitialized;
    if (pause) {
      try {
        await controller.stopImageStream();
      } catch (_) {}
      try {
        await controller.pausePreview();
      } catch (_) {}
    }
    try {
      await app.addScannedPage(document: widget.document, rawPath: rawPath, crop: crop);
    } finally {
      if (pause && mounted && controller.value.isInitialized) {
        try {
          await controller.resumePreview();
        } catch (_) {}
        await _startImageStream(controller);
      }
    }
  }

  /// 自動モードの案内文 (状態ごと)。
  String _autoStatusText(int nextPage) {
    if (_busy) return '保存中…';
    switch (_live.value.phase) {
      case LivePhase.countdown:
        return 'そのまま動かさないでください (動かすと取りやめ)';
      case LivePhase.captured:
        return '✓ ${nextPage - 1}ページ目を保存しました。次の紙に入れ替えてください';
      case LivePhase.searching:
        return '紙をかざして止めると、3・2・1 と数えて撮影します';
    }
  }

  /// 輝度化を別 isolate で行う。インスタンスメソッド内のクロージャを Isolate.run に渡すと
  /// State やカメラまで一緒に送ろうとして「object is unsendable」で必ず失敗し、
  /// 自動撮影が毎回「紙面を検出できませんでした」になっていた (README の落とし穴メモ)。
  static Future<Uint8List> _grayInIsolate(img.Image im) =>
      Isolate.run(() => DocumentDetector.toGray(im));

  Future<void> _capture({bool auto = false}) async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture ||
        _busy) {
      return;
    }
    setState(() => _busy = true);
    final app = context.read<AppState>();
    XFile? raw;
    try {
      raw = await controller.takePicture();
      if (!mounted) return;

      if (auto && _live.value.corners != null && _live.value.corners!.length == 4) {
        // 自動モード: 切り抜き画面をスキップして直接保存。
        // コーナーは本撮影画像に学習済みネットをかけた結果のみを使う。
        // null は「紙が写っていない」の意味であり、誤検出を保存しないよう
        // ライブ枠などへフォールバックせず拒否する。
        List<Offset>? corners;
        try {
          final bytes = await File(raw.path).readAsBytes();
          // 端末のデコーダで縮小しながら読む (純 Dart の全画素デコードは実機で約 11 秒)
          final im = await decodeImageCapped(bytes, cap: 512);
          final gray = await _grayInIsolate(im);
          corners = await PaperNet.detectQuad(gray, im.width, im.height);
        } catch (e) {
          debugPrint('auto capture detect failed: $e');
        }
        if (corners == null) {
          try {
            await File(raw.path).delete();
          } catch (_) {}
          // 同じ誤検出位置で連続発火しないよう現在のライブ枠を記録しておく
          _auto.noteManualCapture(_live.value.corners, DateTime.now());
          if (mounted) showSnackBar(context, '紙面を検出できませんでした');
          return;
        }
        await _savePage(app, raw.path, CropResult(corners: corners, rotation: 0));
        if (mounted) {
          showSnackBar(context, '${widget.document.pageCount}ページ目を自動保存しました');
        }
      } else {
        if (!mounted) return;
        final result = await Navigator.of(context).push<CropResult>(
          // fullscreenDialog: 端の近くの四隅ハンドルを動かせるよう、端スワイプで戻る操作を無効にする
          MaterialPageRoute<CropResult>(
              fullscreenDialog: true, builder: (_) => CropScreen(file: raw!)),
        );
        if (result != null && mounted) {
          final app = context.read<AppState>();
          await _savePage(app, raw.path, result);
          if (mounted) {
            showSnackBar(context, '${widget.document.pageCount}ページ目を保存しました');
          }
        }
        // 手動撮影で位置が決まったら自動再武装の基準も更新
        if (_autoMode) {
          _auto.noteManualCapture(_live.value.corners, DateTime.now());
        }
      }
      try {
        await File(raw.path).delete();
      } catch (_) {}
    } catch (e) {
      if (mounted) showSnackBar(context, '保存に失敗しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      _previewBoxAspect = _previewAspect(context, controller);
    }
    return PopScope(
      canPop: !_busy,
      child: EdgeSwipeBack(
        label: '撮影を終える',
        child: Scaffold(
          backgroundColor: Colors.black,
          body: _buildBody(context),
        ),
      ),
    );
  }

  /// 画面上のプレビュー枠のアスペクト比 (幅/高さ)。
  /// controller.value.aspectRatio はセンサー基準 (横長) なので、
  /// CameraPreview と同様に縦画面では逆数にする。
  static double _previewAspect(
      BuildContext context, CameraController controller) {
    final aspect = controller.value.aspectRatio;
    return MediaQuery.orientationOf(context) == Orientation.portrait
        ? 1 / aspect
        : aspect;
  }

  Widget _buildBody(BuildContext context) {
    if (_permissionDenied) {
      return _MessagePane(
        icon: Icons.no_photography_outlined,
        title: 'カメラの利用が許可されていません',
        message: '設定アプリでカメラへのアクセスを許可してください。',
        actionLabel: '設定を開く',
        onAction: openAppSettings,
      );
    }
    if (_error != null) {
      return _MessagePane(
        icon: Icons.error_outline,
        title: 'エラー',
        message: _error!,
        actionLabel: '再試行',
        onAction: _bootstrap,
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    // 教材の既存ページに続く番号 (addScannedPage が保存のたびに pageCount を更新する)
    final pageSoFar = widget.document.pageCount + 1;
    final reduceColors = context.watch<AppState>().reduceColors;
    final aiSharpen = context.watch<AppState>().aiSharpen;
    final dewarp = context.watch<AppState>().dewarp;
    return Stack(
      children: <Widget>[
        Center(
          child: AspectRatio(
            aspectRatio: _previewAspect(context, controller),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                CameraPreview(controller),
                ValueListenableBuilder<LiveOverlay>(
                  valueListenable: _live,
                  builder: (context, overlay, _) => CustomPaint(
                    painter: _LiveQuadPainter(overlay),
                  ),
                ),
                // 枠の中央: カウントダウンの数字 / 撮影済みの ✓
                IgnorePointer(
                  child: ValueListenableBuilder<LiveOverlay>(
                    valueListenable: _live,
                    builder: (context, overlay, _) => ValueListenableBuilder<double?>(
                      valueListenable: _countdown,
                      builder: (context, progress, _) =>
                          _QuadBadge(overlay: overlay, progress: progress),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 紙面ガイド (ライブ検出が出ていないときのヒント)
        IgnorePointer(
          child: ValueListenableBuilder<LiveOverlay>(
            valueListenable: _live,
            builder: (context, overlay, _) {
              if (overlay.corners != null) return const SizedBox.shrink();
              return Center(
                child: Container(
                  width: MediaQuery.of(context).size.width * 0.82,
                  height: MediaQuery.of(context).size.width * 0.82 * 1.35,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white54, width: 1.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.topCenter,
                  child: Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '用紙を枠に収めて撮影',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // 上部バー
        SafeArea(
          child: Row(
            children: <Widget>[
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Text(
                  '${widget.document.title} ・ $pageSoFarページ目',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
              // 自動撮影トグル
              GestureDetector(
                onTap: _busy ? null : _toggleAutoMode,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _autoMode ? const Color(0xFF4CAF50) : Colors.black38,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _autoMode ? Colors.white : Colors.white38,
                      width: 1.2,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.burst_mode,
                        size: 16,
                        color: _autoMode ? Colors.white : Colors.white70,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '自動',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _autoMode ? Colors.white : Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // AI でくっきり (設定画面の「画質」と同じ設定。撮影しながら切り替えられる)
              IconButton(
                tooltip: 'AI でくっきり',
                icon: Icon(
                  aiSharpen ? Icons.auto_awesome : Icons.auto_awesome_outlined,
                  color: aiSharpen ? const Color(0xFFFFC107) : Colors.white70,
                ),
                onPressed: _busy ? null : _toggleAiSharpen,
              ),
              // 曲がり補正 (設定画面の「画質」と同じ設定)
              IconButton(
                tooltip: '曲がり補正',
                icon: Icon(
                  Icons.straighten,
                  color: dewarp ? const Color(0xFF4FC3F7) : Colors.white70,
                ),
                onPressed: _busy ? null : _toggleDewarp,
              ),
              // 減色オプション (色域を認識して自動で色数を減らし軽量化)
              IconButton(
                tooltip: '減色して軽量化 (自動)',
                icon: Icon(
                  Icons.palette_outlined,
                  color: reduceColors
                      ? const Color(0xFF4CAF50)
                      : Colors.white70,
                ),
                onPressed: () {
                  final app = context.read<AppState>();
                  app.setReduceColors(!reduceColors);
                  showSnackBar(
                    context,
                    app.reduceColors
                        ? '減色オン: 色数を自動で絞って軽く保存します'
                        : '減色オフ: フルカラーで保存します',
                  );
                },
              ),
              IconButton(
                icon: Icon(
                  _flash == FlashMode.off ? Icons.flash_off : Icons.flash_auto,
                  color: Colors.white,
                ),
                onPressed: _toggleFlash,
              ),
              if (_cameras.length > 1)
                IconButton(
                  icon: const Icon(Icons.cameraswitch, color: Colors.white),
                  onPressed: _busy ? null : _switchCamera,
                ),
            ],
          ),
        ),
        // 自動モードのステータス (AI 仕上げ中はそちらの表示だけにする)
        if (_autoMode && !(_busy && aiSharpen))
          Positioned(
            left: 0,
            right: 0,
            bottom: 130,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _autoStatusText(pageSoFar),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ),
          ),
        // AI 仕上げは 1 ページ 10 秒ほどかかるので、待っている理由を出す
        if (_busy && context.watch<AppState>().aiSharpen)
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 116),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.auto_awesome, size: 16, color: Colors.white),
                      SizedBox(width: 6),
                      Text('AI でくっきり仕上げ中…',
                          style: TextStyle(color: Colors.white, fontSize: 13)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        // シャッター (自動撮影のカウントダウン中は周りのリングが満ちていく)
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  ValueListenableBuilder<double?>(
                    valueListenable: _countdown,
                    builder: (context, p, _) => p == null
                        ? const SizedBox(width: 90, height: 90)
                        : SizedBox(
                            width: 90,
                            height: 90,
                            child: CircularProgressIndicator(
                              value: p,
                              strokeWidth: 5,
                              color: const Color(0xFF4CAF50),
                              backgroundColor: Colors.white24,
                            ),
                          ),
                  ),
                  GestureDetector(
                    onTap: _busy ? null : _capture,
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.transparent,
                        border: Border.all(color: Colors.white, width: 4),
                      ),
                      padding: const EdgeInsets.all(5),
                      child: Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                        child: _busy
                            ? const Padding(
                                padding: EdgeInsets.all(20),
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: Colors.black54,
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// ライブオーバーレイの表示データ。
/// 自動撮影から見たライブ枠の状態。
enum LivePhase {
  /// 紙を探している / 動いている (白)
  searching,

  /// 止まっていて撮影までカウントダウン中 (緑)
  countdown,

  /// この紙は撮影済み。入れ替え待ち (青)
  captured,
}

/// カウントダウンの進み (0..1) を「3 → 2 → 1」の表示に変える。
int countdownNumber(double progress) => (3 - (progress * 3).floor()).clamp(1, 3);

class LiveOverlay {
  const LiveOverlay({this.corners, this.phase = LivePhase.searching});

  /// プレビュー正規化座標の四隅 [TL,TR,BR,BL]。未検出時は null。
  final List<Offset>? corners;
  final LivePhase phase;

  Color get color => switch (phase) {
        LivePhase.searching => Colors.white70,
        LivePhase.countdown => const Color(0xFF4CAF50),
        LivePhase.captured => const Color(0xFF42A5F5),
      };
}

/// 枠の中央に出す印: カウントダウン中は大きな数字、撮影済みは ✓。
class _QuadBadge extends StatelessWidget {
  const _QuadBadge({required this.overlay, required this.progress});

  final LiveOverlay overlay;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final corners = overlay.corners;
    if (corners == null || corners.length != 4) return const SizedBox.shrink();
    final Widget child;
    if (overlay.phase == LivePhase.countdown && progress != null) {
      child = Text(
        '${countdownNumber(progress!)}',
        key: const ValueKey<String>('countdown-number'),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 88,
          fontWeight: FontWeight.w800,
          shadows: <Shadow>[Shadow(blurRadius: 12, color: Colors.black87)],
        ),
      );
    } else if (overlay.phase == LivePhase.captured) {
      child = Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: overlay.color.withValues(alpha: 0.9),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check, color: Colors.white, size: 44),
      );
    } else {
      return const SizedBox.shrink();
    }
    var cx = 0.0, cy = 0.0;
    for (final c in corners) {
      cx += c.dx / 4;
      cy += c.dy / 4;
    }
    return Align(alignment: Alignment(cx * 2 - 1, cy * 2 - 1), child: child);
  }
}

/// ライブ検出結果の枠 + コーナー点を描くペインター。
class _LiveQuadPainter extends CustomPainter {
  _LiveQuadPainter(this.overlay);

  final LiveOverlay overlay;

  @override
  void paint(Canvas canvas, Size size) {
    final corners = overlay.corners;
    if (corners == null || corners.length != 4) return;
    final pts = <Offset>[
      for (final c in corners) Offset(c.dx * size.width, c.dy * size.height),
    ];
    final line = Paint()
      ..color = overlay.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..isAntiAlias = true;
    final path = Path()
      ..moveTo(pts[0].dx, pts[0].dy)
      ..lineTo(pts[1].dx, pts[1].dy)
      ..lineTo(pts[2].dx, pts[2].dy)
      ..lineTo(pts[3].dx, pts[3].dy)
      ..close();
    canvas.drawPath(path, line);
    final dot = Paint()..color = overlay.color;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.black38;
    for (final p in pts) {
      canvas.drawCircle(p, 6, dot);
      canvas.drawCircle(p, 6, ring);
    }
  }

  @override
  bool shouldRepaint(covariant _LiveQuadPainter oldDelegate) {
    return oldDelegate.overlay != overlay;
  }
}

class _MessagePane extends StatelessWidget {
  const _MessagePane({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final Future<void> Function() onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 64, color: Colors.white54),
            const SizedBox(height: 16),
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () => onAction(),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}
