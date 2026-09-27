/// 教材 (楽譜・プリントなどのまとまり)。
class MusicDocument {
  MusicDocument({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.pageCount = 0,
    this.coverThumbPath,
    List<String>? tags,
  })  : tags = tags ?? <String>[];

  final String id;
  String title;
  final int createdAt;
  int updatedAt;

  /// ホーム画面のグリッドを高速に描画するための非正規化カウンタ。
  int pageCount;

  /// 表紙サムネイルのパス (まだページが無ければ null)。
  String? coverThumbPath;

  /// 検索用タグ (例: 「音階」「基礎」「○月の課題曲」)。
  List<String> tags;
}
