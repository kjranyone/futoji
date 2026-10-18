// ブック画面の並び替えモード: ドラッグで入れ替え → 「完了」で一括保存、取りやめると保存しない。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:futoji/models/adapters.dart';
import 'package:futoji/models/music_document.dart';
import 'package:futoji/models/music_page.dart';
import 'package:futoji/screens/document_screen.dart';
import 'package:futoji/screens/home_screen.dart';
import 'package:futoji/services/db_service.dart';
import 'package:futoji/state/app_state.dart';
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
    tmp = await Directory.systemTemp.createTemp('futoji_reorder_test');
    Hive.init(tmp.path);
    await Hive.openBox<MusicDocument>('documents');
    await Hive.openBox<MusicPage>('pages');
    doc = MusicDocument(
        id: 'doc', title: 'ブック', createdAt: 1, updatedAt: 1, pageCount: 3,
        coverThumbPath: 'thumb-A');
    await DbService.documents.put(doc.id, doc);
    for (final (i, id) in <String>['A', 'B', 'C'].indexed) {
      await DbService.pages.put(
          id,
          MusicPage(
            id: id,
            documentId: 'doc',
            index: i,
            imagePath: 'image-$id',
            thumbPath: 'thumb-$id',
            width: 10,
            height: 14,
            updatedAt: 1,
          ));
    }
    app = AppState();
    await app.refreshDocuments();
  });

  tearDown(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  List<String> savedOrder() {
    final pages = DbService.pages.values.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    return pages.map((p) => p.id).toList();
  }

  Future<void> openReorderMode(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 900));
    await tester.runAsync(() => tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
          value: app,
          child: MaterialApp(home: DocumentScreen(document: doc)),
        )));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('メニュー'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ページを並び替え'));
    await tester.pumpAndSettle();
    expect(find.text('完了'), findsOneWidget);
  }

  /// 1 行目 (A) のつまみを 3 行目の下までドラッグする。
  Future<void> dragFirstToLast(WidgetTester tester) async {
    final handle = find.byIcon(Icons.drag_handle).first;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    for (int i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, 25));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('ドラッグで入れ替えて「完了」で一括保存し、表紙も 1 ページ目に揃える', (tester) async {
    await openReorderMode(tester);
    await dragFirstToLast(tester);
    // 保存前は DB は変わらず、画面には移動元が出る
    expect(savedOrder(), <String>['A', 'B', 'C']);
    expect(find.text('元は 1ページ目'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('完了'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    expect(savedOrder(), <String>['B', 'C', 'A']);
    expect(DbService.documents.get('doc')!.coverThumbPath, 'thumb-B');
    expect(find.text('完了'), findsNothing, reason: '通常表示に戻る');
  });

  testWidgets('並び替えをやめると保存しない (変更があれば確認する)', (tester) async {
    await openReorderMode(tester);
    await dragFirstToLast(tester);

    await tester.tap(find.byTooltip('並び替えをやめる'));
    await tester.pumpAndSettle();
    expect(find.text('並び替えをやめますか？'), findsOneWidget);
    await tester.tap(find.text('保存せずに戻る'));
    await tester.pumpAndSettle();

    expect(savedOrder(), <String>['A', 'B', 'C']);
    expect(find.text('完了'), findsNothing);
  });

  testWidgets('ブック一覧は「全てのブック」・黒背景、ページ一覧も黒背景でメニューも暗い配色', (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
          value: app,
          child: const MaterialApp(home: HomeScreen()),
        )));
    await tester.pumpAndSettle();
    expect(find.text('全てのブック'), findsOneWidget);
    Color bg() => tester
        .widget<Scaffold>(find.byType(Scaffold).last)
        .backgroundColor ??
        Theme.of(tester.element(find.byType(Scaffold).last)).scaffoldBackgroundColor;
    expect(bg(), Colors.black);

    await tester.tap(find.text('ブック'));
    await tester.pumpAndSettle();
    expect(find.byType(DocumentScreen), findsOneWidget);
    expect(bg(), Colors.black);

    // 右上のメニュー (ボトムシート) も暗い配色になる
    await tester.tap(find.byTooltip('メニュー'));
    await tester.pumpAndSettle();
    final sheetTheme = Theme.of(tester.element(find.text('ページを並び替え')));
    expect(sheetTheme.brightness, Brightness.dark);
  });
}
