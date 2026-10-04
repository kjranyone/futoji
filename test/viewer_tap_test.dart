// ビューアの漫画ビューア風タップ操作: 左右 1/3 でページ送り、中央でバーの表示切替。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:mymusicbook/models/adapters.dart';
import 'package:mymusicbook/models/music_document.dart';
import 'package:mymusicbook/models/music_page.dart';
import 'package:mymusicbook/screens/viewer_screen.dart';
import 'package:mymusicbook/services/db_service.dart';
import 'package:mymusicbook/state/app_state.dart';
import 'package:provider/provider.dart';

void main() {
  late Directory tmp;
  late AppState app;
  late MusicDocument doc;

  setUpAll(() {
    Hive.registerAdapter(MusicDocumentAdapter());
    Hive.registerAdapter(MusicPageAdapter());
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mmb_viewer_tap_test');
    Hive.init(tmp.path);
    await Hive.openBox<MusicDocument>('documents');
    await Hive.openBox<MusicPage>('pages');
    doc = MusicDocument(id: 'doc', title: '教材', createdAt: 1, updatedAt: 1, pageCount: 3);
    await DbService.documents.put(doc.id, doc);
    for (int i = 0; i < 3; i++) {
      await DbService.pages.put(
          'p$i',
          MusicPage(
            id: 'p$i',
            documentId: 'doc',
            index: i,
            imagePath: '${tmp.path}/none$i.webp', // 画像が無くても表示は崩れない
            thumbPath: '',
            width: 1000,
            height: 1400,
            updatedAt: 1,
          ));
    }
    app = AppState();
    await app.refreshDocuments();
    await app.reloadPages('doc');
  });

  tearDown(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  test('横位置を 3 つの領域に分ける', () {
    expect(tapZoneOf(0.1), TapZone.previous);
    expect(tapZoneOf(0.5), TapZone.center);
    expect(tapZoneOf(0.9), TapZone.next);
  });

  testWidgets('右タップで次、左タップで前のページ、中央タップでバーの表示を切り替える',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(home: ViewerScreen(document: doc, initialIndex: 0)),
    ));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);

    // ダブルタップ判定を待つので、タップのあと少し時間を進める
    Future<void> tapAt(double fx) async {
      await tester.tapAt(Offset(600 * fx, 450));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    await tapAt(0.9);
    expect(find.text('2 / 3'), findsOneWidget);
    await tapAt(0.9);
    expect(find.text('3 / 3'), findsOneWidget);
    await tapAt(0.9);
    expect(find.text('最後のページです'), findsOneWidget);
    expect(find.text('3 / 3'), findsOneWidget);

    await tapAt(0.1);
    expect(find.text('2 / 3'), findsOneWidget);

    // 中央: バーを隠す → もう一度で戻す
    await tapAt(0.5);
    expect(find.byType(AppBar), findsNothing);
    await tapAt(0.5);
    expect(find.text('2 / 3'), findsOneWidget);
  });
}
