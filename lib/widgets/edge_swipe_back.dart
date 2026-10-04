import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 左端からの右スワイプで前の画面に戻る帯を [child] の上に重ねる。
///
/// 指を動かしている間は「← [label]」の吹き出しが指の高さで端から出てきて、
/// 戻れる位置まで引くと色が変わり軽く振動する。そこで離すと戻り、手前で離すと引っ込む。
///
/// 画面遷移の端スワイプ (CupertinoPageTransitionsBuilder) は、画面内に横スクロール
/// (PageView など) やズーム (InteractiveViewer) があるとジェスチャの取り合いに負けて
/// 効かないため、この帯は端に触れた指を即座に確保する。
class EdgeSwipeBack extends StatefulWidget {
  const EdgeSwipeBack({
    super.key,
    required this.child,
    this.label = '戻る',
    this.enabled = true,
  });

  final Widget child;

  /// 吹き出しに出す行き先 (例: 「一覧に戻る」)。
  final String label;

  /// false の間は帯を置かない (手書き中など、端の近くの操作を優先する)。
  final bool enabled;

  /// 帯の幅 (CupertinoPageRoute の端スワイプ領域と同じ 20)。
  static const double edgeWidth = 20;

  /// この距離だけ引くと戻れる状態になる (論理ピクセル)。
  static const double triggerDistance = 96;

  /// これより速く払えば距離が足りなくても戻る (論理ピクセル/秒)。
  static const double flingVelocity = 700;

  @override
  State<EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<EdgeSwipeBack>
    with SingleTickerProviderStateMixin {
  /// 吹き出しの出具合 (0 = 隠れている, 1 = 戻れる位置)。離したときはここから 0 へ戻す。
  late final AnimationController _progress =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  double _y = 0;
  bool _armed = false;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _onStart(Offset local) {
    _progress.stop();
    setState(() {
      _y = local.dy;
      _armed = false;
    });
    _progress.value = 0;
  }

  void _onUpdate(double dx, Offset local) {
    final p = (dx / EdgeSwipeBack.triggerDistance).clamp(0.0, 1.0);
    final armed = p >= 1.0;
    if (armed && !_armed) HapticFeedback.selectionClick();
    setState(() {
      _y = local.dy;
      _armed = armed;
    });
    _progress.value = p;
  }

  void _onEnd(double dx, double velocity) {
    final go = _armed || velocity > EdgeSwipeBack.flingVelocity && dx > 24;
    _progress.animateTo(0, curve: Curves.easeOut);
    setState(() => _armed = false);
    if (go) Navigator.of(context).maybePop();
  }

  void _onCancel() {
    _progress.animateTo(0, curve: Curves.easeOut);
    setState(() => _armed = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: <Widget>[
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: EdgeSwipeBack.edgeWidth,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque, // 下の PageView に渡さず帯だけが受け取る
            gestures: <Type, GestureRecognizerFactory>{
              _EdgeDragRecognizer: GestureRecognizerFactoryWithHandlers<_EdgeDragRecognizer>(
                () => _EdgeDragRecognizer(debugOwner: this),
                (r) => r
                  ..onEdgeDragStart = _onStart
                  ..onEdgeDragUpdate = _onUpdate
                  ..onEdgeDragEnd = _onEnd
                  ..onEdgeDragCancel = _onCancel,
              ),
            },
          ),
        ),
        // 吹き出し (タッチは受けない)
        AnimatedBuilder(
          animation: _progress,
          builder: (context, _) {
            final p = _progress.value;
            if (p <= 0) return const SizedBox.shrink();
            final height = MediaQuery.sizeOf(context).height;
            const bubbleHeight = 48.0;
            final top = (_y - bubbleHeight / 2)
                .clamp(8.0, math.max(8.0, height - bubbleHeight - 8))
                .toDouble();
            final bg = _armed ? scheme.primary : scheme.surfaceContainerHighest;
            final fg = _armed ? scheme.onPrimary : scheme.onSurfaceVariant;
            return Positioned(
              // 端の外から指に合わせて滑り出る
              left: -160 + 172 * Curves.easeOut.transform(p),
              top: top,
              child: IgnorePointer(
                child: Opacity(
                  opacity: (p * 1.5).clamp(0.0, 1.0),
                  child: Material(
                    key: const ValueKey<String>('edge-swipe-indicator'),
                    color: bg,
                    elevation: 4,
                    shape: const StadiumBorder(),
                    child: SizedBox(
                      height: bubbleHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(Icons.arrow_back, color: fg, size: 20),
                            const SizedBox(width: 8),
                            Text(widget.label,
                                style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// 指が帯に触れた時点でジェスチャの取り合いに勝ち (画面遷移の端スワイプや
/// PageView に渡さない)、横移動量と速度を通知する。
class _EdgeDragRecognizer extends OneSequenceGestureRecognizer {
  _EdgeDragRecognizer({super.debugOwner});

  void Function(Offset local)? onEdgeDragStart;
  void Function(double dx, Offset local)? onEdgeDragUpdate;
  void Function(double dx, double velocity)? onEdgeDragEnd;
  VoidCallback? onEdgeDragCancel;

  VelocityTracker? _tracker;
  double _startX = 0;
  double _lastX = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
    _tracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
    _startX = _lastX = event.position.dx;
    onEdgeDragStart?.call(event.localPosition);
  }

  @override
  void handleEvent(PointerEvent event) {
    _tracker?.addPosition(event.timeStamp, event.position);
    if (event is PointerMoveEvent) {
      _lastX = event.position.dx;
      onEdgeDragUpdate?.call(_lastX - _startX, event.localPosition);
    } else if (event is PointerUpEvent) {
      final v = _tracker?.getVelocity().pixelsPerSecond.dx ?? 0;
      onEdgeDragEnd?.call(_lastX - _startX, v);
      stopTrackingPointer(event.pointer);
    } else if (event is PointerCancelEvent) {
      onEdgeDragCancel?.call();
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _tracker = null;
  }

  @override
  String get debugDescription => 'edge swipe back';
}
