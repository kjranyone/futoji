import 'stroke.dart';

/// 教材の 1 ページ。画像は WebP でローカル保存し、
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

  /// 教材内の表示順 (0 起点)
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
}
