// 保存後のページ回転で、縦横・手書きメモが正しく入れ替わることと、
// 1.0.3〜1.0.4 の回転で正方形として記録されたページの修復を検証する。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:futoji/models/adapters.dart';
import 'package:futoji/models/music_document.dart';
import 'package:futoji/models/music_page.dart';
import 'package:futoji/models/stroke.dart';
import 'package:futoji/services/db_service.dart';
import 'package:futoji/state/app_state.dart';
import 'package:hive_ce/hive.dart';

MusicPage page({int width = 300, int height = 200, List<Stroke>? strokes}) => MusicPage(
      id: 'p1',
      documentId: 'd1',
      index: 0,
      imagePath: '/img/p1.webp',
      thumbPath: '/thumb/p1.webp',
      width: width,
      height: height,
      updatedAt: 0,
      strokes: strokes,
    );

void main() {
  group('MusicPage.rotate90', () {
    test('縦横が入れ替わる (正方形にならない)', () {
      final p = page()
        ..rotate90(clockwise: true, imagePath: '/img/a', thumbPath: '/thumb/a', updatedAt: 5);
      expect((p.width, p.height), (200, 300));
      expect((p.imagePath, p.thumbPath, p.updatedAt), ('/img/a', '/thumb/a', 5));
    });

    test('右に 4 回、または右・左で元に戻る (縦横・手書き・線の太さ)', () {
      const pts = <Offset>[Offset(0.1, 0.2), Offset(0.7, 0.9)];
      for (final turns in const <List<bool>>[
        <bool>[true, true, true, true],
        <bool>[true, false],
        <bool>[false, false, false, false],
      ]) {
        final p = page(strokes: <Stroke>[Stroke(color: 1, width: 0.01, points: pts)]);
        for (final cw in turns) {
          p.rotate90(clockwise: cw, imagePath: 'i', thumbPath: 't', updatedAt: 0);
        }
        expect((p.width, p.height), (300, 200), reason: '$turns');
        final s = p.strokes.single;
        expect(s.width, closeTo(0.01, 1e-12), reason: '$turns');
        for (int i = 0; i < pts.length; i++) {
          expect((s.points[i] - pts[i]).distance, lessThan(1e-12), reason: '$turns');
        }
      }
    });

    test('手書きの太さは回す前の縦横比で直す', () {
      final p = page(strokes: <Stroke>[Stroke(color: 1, width: 0.01, points: const <Offset>[])])
        ..rotate90(clockwise: true, imagePath: 'i', thumbPath: 't', updatedAt: 0);
      // 幅 300 の 1% = 3px は、回した後の幅 200 では 1.5%
      expect(p.strokes.single.width, closeTo(0.015, 1e-12));
    });
  });

  group('正方形として記録されたページの修復', () {
    late Directory root;

    setUpAll(() async {
      root = await Directory.systemTemp.createTemp('futoji_rotation_test');
      Hive.init(root.path);
      Hive.registerAdapter(MusicDocumentAdapter());
      Hive.registerAdapter(MusicPageAdapter());
    });

    setUp(() async {
      await Hive.openBox<MusicDocument>('documents');
      await Hive.openBox<MusicPage>('pages');
    });

    tearDown(() async {
      await DbService.pages.clear();
      await Hive.close();
    });

    tearDownAll(() => root.delete(recursive: true));

    test('画像の大きさと違えば直し、本当に正方形・未記録のページは触らない', () async {
      final sizes = <String, (int, int)>{
        '/broken': (200, 300), // 回転で 300x300 と記録された 200x300 のページ
        '/square': (500, 500),
      };
      final pages = <MusicPage>[
        MusicPage(id: 'broken', documentId: 'd', index: 0, imagePath: '/broken',
            thumbPath: '', width: 300, height: 300, updatedAt: 0),
        MusicPage(id: 'square', documentId: 'd', index: 1, imagePath: '/square',
            thumbPath: '', width: 500, height: 500, updatedAt: 0),
        MusicPage(id: 'normal', documentId: 'd', index: 2, imagePath: '/normal',
            thumbPath: '', width: 300, height: 400, updatedAt: 0),
        MusicPage(id: 'unknown', documentId: 'd', index: 3, imagePath: '/unknown',
            thumbPath: '', width: 0, height: 0, updatedAt: 0),
      ];
      for (final p in pages) {
        await DbService.pages.put(p.id, p);
      }
      final asked = <String>[];
      await AppState().repairPageSizes(readSize: (path) async {
        asked.add(path);
        return sizes[path];
      });
      // 正方形と記録されたページだけ画像を読む
      expect(asked, unorderedEquals(<String>['/broken', '/square']));
      int w(String id) => DbService.pages.get(id)!.width;
      int h(String id) => DbService.pages.get(id)!.height;
      expect((w('broken'), h('broken')), (200, 300));
      expect((w('square'), h('square')), (500, 500));
      expect((w('normal'), h('normal')), (300, 400));
      expect((w('unknown'), h('unknown')), (0, 0));
    });

    test('画像が読めなければそのまま', () async {
      await DbService.pages.put('p', page(width: 300, height: 300));
      await AppState().repairPageSizes(readSize: (_) async => null);
      expect(DbService.pages.get('p')!.width, 300);
    });
  });
}
