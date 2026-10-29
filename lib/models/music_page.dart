import 'stroke.dart';

/// ブックの 1 ページ。画像は WebP でローカル保存し、
/// 手書きメモはベクトル (Stroke) としてこのレコードに持つ。
class MusicPage {
  MusicPage({
    required this.id,
    required this.documentId,
    required this.index,
    required this.imagePath,
    required this.thumbPath,
    required this.width,
    required this.height,
    required this.updatedAt,
    List<Stroke>? strokes,
    this.note = '',
  })  : strokes = strokes ?? <Stroke>[];

  final String id;
  final String documentId;

  /// ブック内の表示順 (0 起点)
  int index;

  /// 本文画像 (WebP) の絶対パス
  String imagePath;

  /// サムネイル (WebP) の絶対パス
  String thumbPath;

  /// 台形補正後の画像サイズ (px)
  int width;
  int height;

  /// 手書きメモ (画像の上に重ねて描画)
  List<Stroke> strokes;

  /// ページメモ (検索 Index の対象になる自由記述)。
  /// 例: 「3ページ目の音階練習」「ここで転調」
  String note;

  int updatedAt;

  /// 90 度回したページに書き換える ([clockwise] なら右回り)。画像は回して書き直した
  /// [imagePath] / [thumbPath] に差し替え、縦横を入れ替え、手書きメモも同じ向きに回す。
  void rotate90({
    required bool clockwise,
    required String imagePath,
    required String thumbPath,
    required int updatedAt,
  }) {
    final aspect = width > 0 && height > 0 ? width / height : 1.0;
    strokes = <Stroke>[
      for (final s in strokes) s.rotated90(clockwise: clockwise, pageAspect: aspect)
    ];
    final oldWidth = width;
    width = height;
    height = oldWidth;
    this.imagePath = imagePath;
    this.thumbPath = thumbPath;
    this.updatedAt = updatedAt;
  }

  /// 保存されている縦横 ([width] x [height]) が画像の実際の大きさと食い違っていれば直す。
  /// 1.0.3〜1.0.4 の回転で縦横がどちらも元の高さ (正方形) になっていたページの修復用。
  /// 直したら true。
  bool fixSize(int actualWidth, int actualHeight) {
    if (actualWidth <= 0 || actualHeight <= 0) return false;
    if (width == actualWidth && height == actualHeight) return false;
    width = actualWidth;
    height = actualHeight;
    return true;
  }
}
