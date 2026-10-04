import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 左端からの右スワイプで前の画面に戻る帯を [child] の上に重ねる。
///
/// 画面遷移の端スワイプ (CupertinoPageTransitionsBuilder) は、画面内に横スクロール
/// (PageView など) やズーム (InteractiveViewer) があるとジェスチャの取り合いに負けて
/// 効かない。そういう画面では、この帯が端に触れた指を即座に確保して戻る。
class EdgeSwipeBack extends StatefulWidget {
  const EdgeSwipeBack({super.key, required this.child, this.enabled = true});

  final Widget child;

  /// false の間は帯を置かない (手書き中など、端の近くの操作を優先する)。
  final bool enabled;

  /// 帯の幅 (CupertinoPageRoute の端スワイプ領域と同じ 20)。
  static const double edgeWidth = 20;

  @override
  State<EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<EdgeSwipeBack> {
  void _onEnd(double dx, double velocity) {
    final width = MediaQuery.sizeOf(context).width;
    if (velocity > 400 || dx > width * 0.25) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
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
                (r) => r.onEdgeDragEnd = _onEnd,
              ),
            },
          ),
        ),
      ],
    );
  }
}

/// 指が帯に触れた時点でジェスチャの取り合いに勝ち (画面遷移の端スワイプや
/// PageView に渡さない)、離したときの横移動量と速度を返す。
class _EdgeDragRecognizer extends OneSequenceGestureRecognizer {
  _EdgeDragRecognizer({super.debugOwner});

  void Function(double dx, double velocity)? onEdgeDragEnd;

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
  }

  @override
  void handleEvent(PointerEvent event) {
    _tracker?.addPosition(event.timeStamp, event.position);
    if (event is PointerMoveEvent) {
      _lastX = event.position.dx;
    } else if (event is PointerUpEvent) {
      final v = _tracker?.getVelocity().pixelsPerSecond.dx ?? 0;
      onEdgeDragEnd?.call(_lastX - _startX, v);
      stopTrackingPointer(event.pointer);
    } else if (event is PointerCancelEvent) {
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
