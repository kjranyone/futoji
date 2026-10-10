import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/gestures.dart' show DeviceGestureSettings;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:image/image.dart' as img;

import '../models/crop_result.dart';
import '../services/detector.dart';
import '../services/fast_decode.dart';
import '../services/paper_net.dart';
import '../services/training_capture.dart';
import '../widgets/corner_overlay.dart';
/// isolate に渡すクロージャが State (this) を暗黙キャプチャしないよう、
/// 重い処理は必ず top-level 関数に切り出して sendable な引数だけで呼ぶ。
img.Image _rotateWorkImage(List<Object?> args) {
  return img.copyRotate(args[0] as img.Image, angle: args[1] as int);
}

/// 撮影直後の 1 枚について、紙面の四隅を調整する画面。
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.file});

  final XFile file;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  static Future<img.Image> _rotateInIsolate(img.Image work, int rotation) =>
      Isolate.run(() => _rotateWorkImage(<Object?>[work, rotation]));

  img.Image? _work; // 小さめのワーク画像 (回転 0 度基準)
  Uint8List? _display; // 画面表示用 JPEG
  int _displayW = 0;
  int _displayH = 0;
  List<Offset>? _predicted; // 現在の回転でのモデル予測 (学習データ保存用)
  int _rotation = 0;
  double _aspect = 1;
  List<Offset> _corners = _defaultCorners();
  bool _autoDetected = false;
  bool _loading = true;
  String? _error;

  /// いまドラッグしているハンドル (大きく表示する)。
  int? _dragging;

  static List<Offset> _defaultCorners() => const <Offset>[
        Offset(0.04, 0.06),
        Offset(0.96, 0.06),
        Offset(0.96, 0.94),
        Offset(0.04, 0.94),
      ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.file.readAsBytes();
      // 端末のデコーダで縮小しながら読む (純 Dart の全画素デコードは実機で約 11 秒)
      final work = await decodeWorkImage(bytes);
      _work = work;
      await _applyRotation(0, detect: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  /// 回転を適用して表示を更新する。detect=true なら紙面検出もやり直す。
  Future<void> _applyRotation(int rotation, {required bool detect}) async {
    final work = _work;
    if (work == null) return;
    setState(() => _loading = true);
    final rotated = rotation == 0 ? work : await _rotateInIsolate(work, rotation);
    // 紙面検出は学習済みネットのみ。null は「紙が写っていない」の意味であり、
    // 誤検出しないよう代替検出にはフォールバックしない。
    List<Offset>? quad;
    if (detect) {
      final gray = DocumentDetector.toGray(rotated);
      quad = await PaperNet.detectQuad(gray, rotated.width, rotated.height);
    }
    if (!mounted) return;
    setState(() {
      _rotation = rotation;
      _aspect = rotated.width / rotated.height;
      _display = Uint8List.fromList(img.encodeJpg(rotated, quality: 88));
      _displayW = rotated.width;
      _displayH = rotated.height;
      _predicted = quad == null ? null : List<Offset>.unmodifiable(quad);
      _autoDetected = quad != null;
      if (quad != null) {
        _corners = quad;
      } else {
        _corners = _defaultCorners();
      }
      _loading = false;
    });
  }

  Future<void> _redetect() => _applyRotation(_rotation, detect: true);

  Future<void> _rotate() => _applyRotation((_rotation + 90) % 360, detect: true);

  void _moveCorner(int index, Offset normalized) {
    // 新しいリストに差し替える (const リストの書き換えを避け、
    // CornerOverlayPainter.shouldRepaint が差分を検出できるようにする)
    setState(() {
      _corners = List<Offset>.of(_corners)
        ..[index] = Offset(
          normalized.dx.clamp(0.0, 1.0),
          normalized.dy.clamp(0.0, 1.0),
        );
    });
  }

  void _confirm() {
    final display = _display;
    if (display != null && TrainingCapture.enabled) {
      // 画面に出していた正立画像そのものと、確定した四隅を保存する
      // (座標系が一致する)。保存完了は待たない。
      unawaited(TrainingCapture.save(
        jpeg: display,
        width: _displayW,
        height: _displayH,
        corners: List<Offset>.of(_corners),
        predicted: _predicted,
      ));
    }
    Navigator.of(context).pop(
      CropResult(corners: List<Offset>.of(_corners), rotation: _rotation),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_loading,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('紙面を調整'),
          actions: <Widget>[
            IconButton(
              tooltip: '自動検出',
              icon: const Icon(Icons.auto_fix_high),
              onPressed: _loading ? null : _redetect,
            ),
            IconButton(
              tooltip: '回転',
              icon: const Icon(Icons.rotate_right),
              onPressed: _loading ? null : _rotate,
            ),
            IconButton(
              tooltip: 'この範囲で保存',
              icon: const Icon(Icons.check_circle, size: 28),
              onPressed: _loading ? null : _confirm,
            ),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }
    final display = _display;
    if (display == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final body = SafeArea(
      child: Column(
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              // ハンドルは動かし始めの閾値を小さくして、触れたらすぐ付いてくるようにする
              // (この画面には横スクロールなど競合する操作がない)
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                    gestureSettings: const DeviceGestureSettings(touchSlop: 8)),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final container = constraints.biggest;
                    final rect = containRect(container, _aspect);
                    return Stack(
                      children: <Widget>[
                        Positioned.fromRect(
                          rect: rect,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: Image.memory(display,
                                fit: BoxFit.fill, gaplessPlayback: true),
                          ),
                        ),
                        Positioned.fromRect(
                          rect: rect,
                          child: IgnorePointer(
                            child: CustomPaint(
                              size: rect.size,
                              painter: CornerOverlayPainter(
                                  corners: _corners, rect: Offset.zero & rect.size),
                            ),
                          ),
                        ),
                        for (int i = 0; i < 4; i++)
                          _cornerHandle(i, rect),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                Icon(
                  _autoDetected ? Icons.auto_awesome : Icons.search_off,
                  size: 16,
                  color: _autoDetected ? Colors.white54 : Colors.amberAccent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _autoDetected ? '紙面を自動検出しました' : '四隅をドラッグして紙面に合わせてください',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    // 回転・再検出の間は、いまの画像を残したまま薄暗くして待つ
    // (真っ暗な画面に戻ってから出直すとちらついて見える)
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IgnorePointer(ignoring: _loading, child: body),
        if (_loading)
          const ColoredBox(
            color: Colors.black38,
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  Widget _cornerHandle(int index, Rect rect) {
    final c = _corners[index];
    final pos = Offset(rect.left + c.dx * rect.width,
        rect.top + c.dy * rect.height);
    final active = _dragging == index;
    return Positioned(
      left: pos.dx - 22,
      top: pos.dy - 22,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) {
          _moveCorner(index, Offset(
            (pos.dx + details.delta.dx - rect.left) / rect.width,
            (pos.dy + details.delta.dy - rect.top) / rect.height,
          ));
        },
        // つまんだときに軽く振動し、指の下で見えるようハンドルを大きくする
        onPanStart: (_) {
          HapticFeedback.selectionClick();
          setState(() => _dragging = index);
          _moveCorner(index, c);
        },
        onPanEnd: (_) => setState(() => _dragging = null),
        onPanCancel: () => setState(() => _dragging = null),
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          child: AnimatedScale(
            scale: active ? 1.3 : 1,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: active ? 1 : 0.9),
                border: Border.all(color: const Color(0xFF3B4A9F), width: 3),
                boxShadow: const <BoxShadow>[
                  BoxShadow(color: Colors.black38, blurRadius: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
