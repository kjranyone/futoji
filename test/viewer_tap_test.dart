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

  Future<void> openViewer(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(home: ViewerScreen(document: doc, initialIndex: 0)),
    ));
    await tester.pumpAndSettle();
  }

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
    // 端の知らせは SnackBar ではなく、ページの上の小さな吹き出し (すぐ消える)
    expect(find.text('最後のページです'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('3 / 3'), findsOneWidget);

    await tapAt(0.1);
    expect(find.text('2 / 3'), findsOneWidget);

    // 中央: バーを隠す → もう一度で戻す。
    // バーは消えるのではなく上へ滑り出て (タッチも通さない)、ページはバーの分だけ広がる
    Offset chromeOffset() => tester
        .widget<AnimatedSlide>(find.byKey(const ValueKey<String>('viewer-chrome')))
        .offset;
    double pageTop() => tester.getTopLeft(find.byType(InteractiveViewer).first).dy;
    expect(chromeOffset(), Offset.zero);
    expect(pageTop(), kToolbarHeight, reason: 'バーを出している間はページをその下に収める');

    await tapAt(0.5);
    expect(chromeOffset(), const Offset(0, -1));
    expect(find.byType(AppBar), findsOneWidget, reason: '隠している間も (見えない所に) 残す');
    expect(pageTop(), 0, reason: 'バーを隠すとページが画面の上端まで広がる');
    final ignoring = tester.widget<IgnorePointer>(find
        .ancestor(of: find.byType(AppBar), matching: find.byType(IgnorePointer))
        .first);
    expect(ignoring.ignoring, isTrue, reason: '隠れているバーはタッチを受けない');

    await tapAt(0.5);
    expect(chromeOffset(), Offset.zero);
    expect(pageTop(), kToolbarHeight);
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('タップするとダブルタップの判定を待たずにすぐめくり始める', (tester) async {
    await openViewer(tester);
    await tester.tapAt(const Offset(540, 450));
    // ダブルタップの猶予 (300ms) より短い時間で、もうページが動いている
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('2 / 3'), findsOneWidget,
        reason: 'タップ後 160ms でページ送りのアニメーションが半分を過ぎている');
    await tester.pumpAndSettle();
  });

  testWidgets('手書きの線は指が触れた点から始まる (動き出しを待った位置からではない)',
      (tester) async {
    await openViewer(tester);
    await tester.tap(find.text('手書き'));
    await tester.pumpAndSettle();

    // ページの中央 (= 正規化座標 (0.5, 0.5)) に触れてから右へ引く
    final center = tester.getCenter(find.byType(InteractiveViewer).first);
    final g = await tester.startGesture(center);
    for (int i = 0; i < 5; i++) {
      await g.moveBy(const Offset(12, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // 離すと線が Hive に保存される (実 I/O) ので、runAsync の中で実時間を進めて待つ
    await tester.runAsync(() async {
      await g.up();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    final strokes = app.cachedPages('doc')![0].strokes;
    expect(strokes, hasLength(1));
    final first = strokes.single.points.first;
    expect(first.dx, closeTo(0.5, 0.005), reason: '始点は触れた位置 (動き出しの閾値分ずれない)');
    expect(first.dy, closeTo(0.5, 0.005));
    expect(strokes.single.points.last.dx, greaterThan(first.dx + 0.05));
  });

  testWidgets('ゆっくり短く (幅の 25%) スワイプしてもページがめくれる', (tester) async {
    await openViewer(tester);
    // 速度の計算にはイベントの時刻が要る (省略すると全部 0 秒扱いで速度 0 になる)
    var t = Duration.zero;
    final g = await tester.startGesture(const Offset(400, 450));
    for (int i = 0; i < 10; i++) {
      t += const Duration(milliseconds: 40);
      await g.moveBy(const Offset(-15, 0), timeStamp: t); // 計 150px = 25%、約 375px/秒
      await tester.pump(const Duration(milliseconds: 40));
    }
    await g.up(timeStamp: t); // 動かしながら離す
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
  });

  for (final step in <double>[12, 3]) {
  testWidgets('2 本指で広げると拡大され、ページはめくれない (1 フレーム ${step}px)', (tester) async {
    await openViewer(tester);
    final a = await tester.startGesture(const Offset(260, 450));
    final b = await tester.startGesture(const Offset(340, 450), pointer: 2);
    var t = Duration.zero;
    for (int i = 0; i < (120 / step).round(); i++) {
      t += const Duration(milliseconds: 16);
      await a.moveBy(Offset(-step, -step / 3), timeStamp: t);
      await b.moveBy(Offset(step, step / 3), timeStamp: t);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).first);
    expect(iv.transformationController!.value.getMaxScaleOnAxis(), greaterThan(1.5));
  });
  }

  testWidgets('閲覧中は下のバーを出さず、手書きはヘッダから始める', (tester) async {
    await openViewer(tester);
    expect(find.text('スワイプでページ送り'), findsNothing);
    expect(find.text('消しゴム'), findsNothing, reason: '閲覧中は手書きツールを出さない');
    final header = find.byType(AppBar);
    expect(find.descendant(of: header, matching: find.text('手書き')), findsOneWidget);

    await tester.tap(find.text('手書き'));
    await tester.pumpAndSettle();
    expect(find.text('消しゴム'), findsOneWidget, reason: '手書き中は下にツールを出す');
    expect(find.descendant(of: header, matching: find.text('手書き')), findsNothing,
        reason: '手書き中はヘッダのボタンを隠す');

    await tester.tap(find.byTooltip('閲覧に戻る'));
    await tester.pumpAndSettle();
    expect(find.text('消しゴム'), findsNothing);
  });

  testWidgets('中央タップで操作のヒントが出て、数秒で消える (左右のタップでは出ない)', (tester) async {
    await openViewer(tester);
    double hintOpacity() => tester
        .widget<AnimatedOpacity>(find.byKey(const ValueKey<String>('viewer-hints')))
        .opacity;
    expect(hintOpacity(), 0);

    await tester.tapAt(const Offset(540, 450)); // 右: ページ送りだけ
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(hintOpacity(), 0);

    await tester.tapAt(const Offset(300, 450)); // 中央
    await tester.pump(const Duration(milliseconds: 400));
    expect(hintOpacity(), 1);
    expect(find.text('次のページ'), findsOneWidget);
    expect(find.textContaining('2 本指で拡大'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(hintOpacity(), 0);
  });
}
