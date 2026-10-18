/// 新しく作ったブックの仮の名前。
const String kUntitledBookTitle = '無題のブック';

/// 用語を「ブック」に揃える前の仮の名前。
const String _legacyUntitledTitle = '無題の教材';

/// 保存済みの名前を読むときに使う。名前が無いとき・以前の仮の名前のときは今の仮の名前にする
/// (画面に「教材」が残らないように)。
String bookTitleFrom(String? stored) =>
    stored == null || stored == _legacyUntitledTitle ? kUntitledBookTitle : stored;

/// ブック (楽譜・プリントなどのまとまり)。
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
