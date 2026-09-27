import '../models/music_document.dart';
import '../models/music_page.dart';

/// 検索クエリの解釈と一致判定 (Index 検索の純 Dart コア)。
///
/// 対象: 教材タイトル / 教材タグ / ページメモ。
/// クエリは空白区切りでトークン化し、すべてのトークンが
/// いずれかのフィールドに (大文字小文字を無視して) 含まれる場合に一致。
class DocSearch {
  DocSearch._();

  /// クエリを検索トークンに分割する。
  static List<String> tokens(String query) {
    return query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
  }

  /// 教材がクエリに一致するか。
  /// [pages] はその教材の全ページ (ページメモ検索用)。
  static bool matches(
    MusicDocument doc,
    Iterable<MusicPage> pages,
    String query,
  ) {
    final tokens = DocSearch.tokens(query);
    if (tokens.isEmpty) return true;
    final title = doc.title.toLowerCase();
    final tags = doc.tags.map((t) => t.toLowerCase()).toList(growable: false);
    final notes =
        pages.map((p) => p.note.toLowerCase()).toList(growable: false);
    for (final t in tokens) {
      final hit = title.contains(t) ||
          tags.any((tag) => tag.contains(t)) ||
          notes.any((n) => n.contains(t));
      if (!hit) return false;
    }
    return true;
  }

  /// 一致理由を返す (表示用)。見つからなければ空文字。
  static String matchReason(
    MusicDocument doc,
    Iterable<MusicPage> pages,
    String query,
  ) {
    final tokens = DocSearch.tokens(query);
    final title = doc.title.toLowerCase();
    final tags = doc.tags.map((t) => t.toLowerCase()).toList(growable: false);
    final notes =
        pages.map((p) => p.note.toLowerCase()).toList(growable: false);
    for (final t in tokens) {
      if (title.contains(t)) return 'タイトル';
      if (tags.any((tag) => tag.contains(t))) return 'タグ';
      if (notes.any((n) => n.contains(t))) return 'ページメモ';
    }
    return '';
  }
}
