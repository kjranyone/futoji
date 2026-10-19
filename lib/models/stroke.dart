import 'dart:ui';

/// 1 本の手書き線。
/// 座標はページ画像の幅・高さに対する 0..1 の相対値で保持するため、
/// どの解像度・ズームでも同じ位置に描画される。
class Stroke {
  Stroke({required this.color, required this.width, required this.points});

  /// 線色 (0xAARRGGBB)
  final int color;

  /// 線幅。ページ画像の幅に対する比率。
  final double width;

  /// 頂点列 (正規化座標)
  final List<Offset> points;

  /// ページを 90 度回したときの同じ線 ([clockwise] なら右回り)。
  /// [pageAspect] は回す前のページの幅 / 高さ。線幅はページ幅に対する比率なので、
  /// 幅が変わる分だけ比率を直して太さを保つ。
  Stroke rotated90({required bool clockwise, required double pageAspect}) => Stroke(
        color: color,
        width: width * pageAspect,
        points: <Offset>[
          for (final p in points)
            clockwise ? Offset(1 - p.dy, p.dx) : Offset(p.dy, 1 - p.dx),
        ],
      );

  Map<String, dynamic> toMap() => {
        'c': color,
        'w': width,
        'p': <double>[
          for (final p in points) ...<double>[p.dx, p.dy],
        ],
      };

  static Stroke fromMap(Map<String, dynamic> map) {
    final flat = (map['p'] as List<dynamic>? ?? const <dynamic>[])
        .map((e) => (e as num).toDouble())
        .toList(growable: false);
    final points = <Offset>[
      for (int i = 0; i + 1 < flat.length; i += 2)
        Offset(flat[i], flat[i + 1]),
    ];
    return Stroke(
      color: (map['c'] as num?)?.toInt() ?? 0xFF1A1A1A,
      width: (map['w'] as num?)?.toDouble() ?? 0.006,
      points: points,
    );
  }
}
