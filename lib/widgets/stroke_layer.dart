import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/stroke.dart';

/// 手書きレイヤーの描画。strokes の正規化座標を [rect] に伸縮して描く。
///
/// すべてのストロークは白の縁取りを下敷きにして描くため、
/// 黒ペンでも暗い紙面の上で視認できる。
class StrokeLayerPainter extends CustomPainter {
  StrokeLayerPainter({
    required this.strokes,
    required this.rect,
    this.current,
  }) : _currentLength = current?.points.length ?? 0;

  final List<Stroke> strokes;
  final Rect rect;
  final Stroke? current;

  /// current.points は描画中に in-place で伸びるため、生成時点の点数を
  /// 控えておき shouldRepaint で比較する。
  final int _currentLength;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      _paintStroke(canvas, s);
    }
    if (current != null) {
      _paintStroke(canvas, current!);
    }
  }

  void _paintStroke(Canvas canvas, Stroke s) {
    if (s.points.isEmpty) return;
    final width = (s.width * rect.width).clamp(1.0, 80.0);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.white
      ..strokeWidth = width + 3.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    if (s.points.length == 1) {
      // タップ 1 回 → 点として描く
      final p = _toCanvas(s.points.first);
      canvas.drawCircle(p, outline.strokeWidth / 2, Paint()..color = Colors.white);
      canvas.drawCircle(p, width / 2, Paint()..color = Color(s.color));
      return;
    }
    final path = ui.Path()
      ..moveTo(_toCanvas(s.points.first).dx, _toCanvas(s.points.first).dy);
    for (int i = 1; i < s.points.length; i++) {
      final p = _toCanvas(s.points[i]);
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, outline);
    stroke.color = Color(s.color);
    canvas.drawPath(path, stroke);
  }

  Offset _toCanvas(Offset normalized) =>
      Offset(rect.left + normalized.dx * rect.width,
          rect.top + normalized.dy * rect.height);

  /// 消しゴム用の当たり判定。点だけでなく「線分」への距離も見るため、
  /// 細い線に沿って擦るだけでも消える。
  static bool hitsNormalized(Stroke s, Offset normalized, double radius) {
    final pts = s.points;
    if (pts.isEmpty) return false;
    if (pts.length == 1) {
      return (pts.first - normalized).distance <= radius;
    }
    for (int i = 0; i + 1 < pts.length; i++) {
      if (_distanceToSegment(normalized, pts[i], pts[i + 1]) <= radius) {
        return true;
      }
    }
    return false;
  }

  /// 点 p と線分 ab の最短距離 (正規化座標系)。
  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (l2 == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / l2;
    t = t.clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  /// 部分消しゴム: 消去半径に触れた点、または消去半径を通過する線分で
  /// ストロークを切断し、残った区間 (2 点以上) を新しい Stroke として返す。
  /// 触れなければ元のストローク 1 本のリストを返す。
  static List<Stroke> splitStroke(Stroke s, Offset normalized, double radius) {
    if (s.points.isEmpty) return const <Stroke>[];
    if (!hitsNormalized(s, normalized, radius)) return <Stroke>[s];
    if (s.points.length == 1) return const <Stroke>[];
    final out = <Stroke>[];
    var current = <Offset>[];
    void flush() {
      if (current.length >= 2) {
        out.add(_copyWithPoints(s, current));
      }
      current = <Offset>[];
    }

    for (final p in s.points) {
      if ((p - normalized).distance <= radius) {
        flush();
        continue;
      }
      // 点の間隔が広い (速い) ストロークでは、両端点が半径外でも
      // 線分の途中が消去半径を通ることがある → その線分で切る
      if (current.isNotEmpty &&
          _distanceToSegment(normalized, current.last, p) <= radius) {
        flush();
      }
      current.add(p);
    }
    flush();
    return out;
  }

  static Stroke _copyWithPoints(Stroke s, List<Offset> points) =>
      Stroke(color: s.color, width: s.width, points: points);

  @override
  bool shouldRepaint(covariant StrokeLayerPainter oldDelegate) {
    return oldDelegate.rect != rect ||
        oldDelegate.current != current ||
        oldDelegate._currentLength != _currentLength ||
        !identical(oldDelegate.strokes, strokes) ||
        oldDelegate.strokes.length != strokes.length;
  }
}

/// undo 履歴に保持する最大ステップ数。
const int kMaxUndoSteps = 50;

/// undo 用にストロークリストの独立したコピーを作る。
List<Stroke> snapshotStrokes(List<Stroke> strokes) {
  return <Stroke>[
    for (final s in strokes)
      Stroke(color: s.color, width: s.width, points: List<Offset>.of(s.points)),
  ];
}
