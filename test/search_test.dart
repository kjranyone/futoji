import 'package:flutter_test/flutter_test.dart';

import 'package:futoji/models/music_document.dart';
import 'package:futoji/models/music_page.dart';
import 'package:futoji/services/search.dart';

void main() {
  MusicDocument doc({
    String title = '無題の教材',
    List<String> tags = const <String>[],
  }) =>
      MusicDocument(
        id: 'doc1',
        title: title,
        createdAt: 0,
        updatedAt: 0,
        tags: tags,
      );

  MusicPage page({String note = ''}) => MusicPage(
        id: 'p1',
        documentId: 'doc1',
        index: 0,
        imagePath: '/tmp/a.webp',
        thumbPath: '/tmp/t.webp',
        width: 100,
        height: 140,
        updatedAt: 0,
        note: note,
      );

  group('DocSearch.tokens', () {
    test('空白区切りでトークン化し小文字化する', () {
      expect(DocSearch.tokens('  音階  Scale '), <String>['音階', 'scale']);
      expect(DocSearch.tokens('   '), <String>[]);
    });
  });

  group('DocSearch.matches (Index 検索)', () {
    test('タイトル一致', () {
      final d = doc(title: 'バイオリン基礎テキスト');
      expect(DocSearch.matches(d, const <MusicPage>[], '基礎'), isTrue);
      expect(DocSearch.matches(d, const <MusicPage>[], 'ピアノ'), isFalse);
    });

    test('タグ一致', () {
      final d = doc(title: '無題の教材', tags: <String>['音階', '発表会']);
      expect(DocSearch.matches(d, const <MusicPage>[], '発表会'), isTrue);
      expect(DocSearch.matches(d, const <MusicPage>[], 'コンクール'), isFalse);
    });

    test('ページメモ一致', () {
      final pages = <MusicPage>[page(note: '3ページ目の音階練習')];
      final d = doc(title: '無題の教材');
      expect(DocSearch.matches(d, pages, '音階練習'), isTrue);
      expect(DocSearch.matches(d, const <MusicPage>[], '音階練習'), isFalse,
          reason: 'ページが無ければメモでは一致しない');
    });

    test('複数トークンは AND 条件', () {
      final d = doc(title: '基礎テキスト', tags: <String>['音階']);
      expect(DocSearch.matches(d, const <MusicPage>[], '基礎 音階'), isTrue);
      expect(DocSearch.matches(d, const <MusicPage>[], '基礎 発表会'), isFalse);
    });

    test('空クエリは常時一致', () {
      expect(DocSearch.matches(doc(), const <MusicPage>[], ''), isTrue);
      expect(DocSearch.matches(doc(), const <MusicPage>[], '  '), isTrue);
    });

    test('大文字小文字を無視', () {
      final d = doc(title: 'Scales Vol.1');
      expect(DocSearch.matches(d, const <MusicPage>[], 'scales'), isTrue);
      expect(DocSearch.matches(d, const <MusicPage>[], 'VOL'), isTrue);
    });
  });

  group('DocSearch.matchReason (一致理由の表示)', () {
    test('優先順: タイトル > タグ > ページメモ', () {
      final d = doc(title: '音階', tags: <String>['音階']);
      final pages = <MusicPage>[page(note: '音階の練習')];
      expect(DocSearch.matchReason(d, pages, '音階'), 'タイトル');
      expect(DocSearch.matchReason(doc(title: '無題', tags: <String>['音階']),
          pages, '音階'), 'タグ');
      expect(
          DocSearch.matchReason(doc(title: '無題'), pages, '音階'), 'ページメモ');
      expect(DocSearch.matchReason(doc(), const <MusicPage>[], ''), '');
    });
  });
}
