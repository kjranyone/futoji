import 'dart:math' as math;
import 'dart:ui';

/// 紙面四隅のラベル (学習・評価データ 1 件分)。
///
/// 保存形式は `<id>.jpg` + `<id>.json` の組。JSON の座標はすべて
/// 画像 (EXIF・回転反映済み、正立) に対する 0..1 正規化座標 [TL,TR,BR,BL]。
///
/// ```json
/// {
///   "version": 1,
///   "image": "<id>.jpg",
///   "width": 750, "height": 1000,
///   "corners": [[x,y],[x,y],[x,y],[x,y]] | null,  // null = 紙が写っていない (ネガティブ)
///   "predicted": [[x,y],...] | null,   // 保存時点のモデル出力 (null = 未検出)
///   "edited": true,                    // ユーザーが四隅を手で動かしたか
///   "source": "app_crop",
///   "created_at": "2026-09-28T03:00:00.000"
/// }
/// ```
class QuadLabel {
  const QuadLabel({
    required this.image,
    required this.width,
    required this.height,
    required this.corners,
    this.predicted,
    this.edited = false,
    this.source = 'app_crop',
    this.createdAt,
  });

  static const int formatVersion = 1;

  final String image;
  final int width;
  final int height;
  /// 正解の四隅。null は「紙が写っていない」(誤検出の評価用)。
  final List<Offset>? corners;

  bool get isNegative => corners == null;
  final List<Offset>? predicted;
  final bool edited;
  final String source;
  final DateTime? createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': formatVersion,
        'image': image,
        'width': width,
        'height': height,
        'corners': corners == null ? null : _encode(corners!),
        'predicted': predicted == null ? null : _encode(predicted!),
        'edited': edited,
        'source': source,
        'created_at': createdAt?.toIso8601String(),
      };

  static QuadLabel fromJson(Map<String, Object?> json) {
    final rawCorners = json['corners'];
    final corners = _decode(rawCorners);
    if (rawCorners != null && corners == null) {
      throw const FormatException('corners が 4 点ではありません');
    }
    final created = json['created_at'];
    return QuadLabel(
      image: json['image']! as String,
      width: (json['width']! as num).toInt(),
      height: (json['height']! as num).toInt(),
      corners: corners,
      predicted: _decode(json['predicted']),
      edited: json['edited'] as bool? ?? false,
      source: json['source'] as String? ?? 'unknown',
      createdAt: created is String ? DateTime.tryParse(created) : null,
    );
  }

  static List<List<double>> _encode(List<Offset> pts) => <List<double>>[
        for (final p in pts) <double>[_round(p.dx), _round(p.dy)],
      ];

  static double _round(double v) => (v * 1e5).roundToDouble() / 1e5;

  static List<Offset>? _decode(Object? raw) {
    if (raw is! List || raw.length != 4) return null;
    return <Offset>[
      for (final p in raw)
        Offset(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];
  }
}

/// 四隅の評価指標。座標は正規化座標で受け取り、画像の縦横比を考慮した
/// ピクセル空間 (width×height) で測る。
class QuadMetrics {
  QuadMetrics._();

  /// 対応する角どうしの距離を画像対角線長で割った値 (平均と最大)。
  ///
  /// 角の並び順の起点が違っても不当に悪化しないよう、同じ巡回向きの
  /// 4 通りのずらしのうち平均誤差が最小のものを採用する。
  static ({double mean, double max}) cornerError(
    List<Offset> predicted,
    List<Offset> truth,
    int width,
    int height,
  ) {
    final diag = math.sqrt(width * width + height * height.toDouble());
    double bestMean = double.infinity;
    double bestMax = double.infinity;
    for (int shift = 0; shift < 4; shift++) {
      double sum = 0;
      double mx = 0;
      for (int i = 0; i < 4; i++) {
        final p = predicted[(i + shift) % 4];
        final t = truth[i];
        final d = math.sqrt(math.pow((p.dx - t.dx) * width, 2) +
                math.pow((p.dy - t.dy) * height, 2)) /
            diag;
        sum += d;
        if (d > mx) mx = d;
      }
      final mean = sum / 4;
      if (mean < bestMean) {
        bestMean = mean;
        bestMax = mx;
      }
    }
    return (mean: bestMean, max: bestMax);
  }

  /// 2 つの四角形の IoU。[grid]×[grid] 相当の格子点サンプリングで近似する
  /// (縦横比は画像に合わせる)。
  static double quadIoU(
    List<Offset> a,
    List<Offset> b,
    int width,
    int height, {
    int grid = 256,
  }) {
    final long = math.max(width, height);
    final gw = math.max(1, (grid * width / long).round());
    final gh = math.max(1, (grid * height / long).round());
    int inter = 0;
    int union = 0;
    for (int y = 0; y < gh; y++) {
      final py = (y + 0.5) / gh;
      for (int x = 0; x < gw; x++) {
        final p = Offset((x + 0.5) / gw, py);
        final ia = _inside(a, p);
        final ib = _inside(b, p);
        if (ia && ib) inter++;
        if (ia || ib) union++;
      }
    }
    return union == 0 ? 0 : inter / union;
  }

  /// 点が多角形内にあるか (偶奇規則)。
  static bool _inside(List<Offset> poly, Offset p) {
    var inside = false;
    for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final a = poly[i];
      final b = poly[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }
}
