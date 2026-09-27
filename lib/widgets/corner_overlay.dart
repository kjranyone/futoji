import 'package:flutter/material.dart';

/// 切り抜き画面の四角形枠 (ハンドルはウィジェット側で置くため線のみ)。
class CornerOverlayPainter extends CustomPainter {
  CornerOverlayPainter({required this.corners, required this.rect});

  /// 正規化座標の四隅 [TL, TR, BR, BL]
  final List<Offset> corners;
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;
    final pts = <Offset>[
      for (final c in corners)
        Offset(rect.left + c.dx * rect.width, rect.top + c.dy * rect.height),
    ];
    final line = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..isAntiAlias = true;

    final path = Path()
      ..moveTo(pts[0].dx, pts[0].dy)
      ..lineTo(pts[1].dx, pts[1].dy)
      ..lineTo(pts[2].dx, pts[2].dy)
      ..lineTo(pts[3].dx, pts[3].dy)
      ..close();
    canvas.drawPath(path, line);

    // 外側を薄暗くして紙面を強調
    canvas.drawPath(
      Path()
        ..addRect(Offset.zero & size)
        ..addPath(path, Offset.zero)
        ..fillType = PathFillType.evenOdd,
      Paint()..color = const Color(0x66000000),
    );
  }

  @override
  bool shouldRepaint(covariant CornerOverlayPainter oldDelegate) {
    return oldDelegate.rect != rect || !_sameCorners(oldDelegate.corners, corners);
  }

  static bool _sameCorners(List<Offset> a, List<Offset> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 表示領域 (container) にアスペクト比 aspect の画像を contain で置いたときの矩形。
Rect containRect(Size container, double aspect) {
  final w = container.width;
  final h = container.height;
  final containerAspect = w / h;
  double imgW, imgH;
  if (aspect > containerAspect) {
    imgW = w;
    imgH = w / aspect;
  } else {
    imgH = h;
    imgW = h * aspect;
  }
  return Rect.fromLTWH((w - imgW) / 2, (h - imgH) / 2, imgW, imgH);
}
