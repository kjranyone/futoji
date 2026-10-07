// 画面の左端からのスワイプで戻れること (Android でも)、
// 端の操作と競合する画面 (fullscreenDialog) では戻らないことを検証する。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mymusicbook/theme.dart';
import 'package:mymusicbook/widgets/edge_swipe_back.dart';

void main() {
  Future<void> pushPage(WidgetTester tester,
      {required bool fullscreenDialog, Widget? page}) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                fullscreenDialog: fullscreenDialog,
                builder: (_) =>
                    page ?? const Scaffold(body: Center(child: Text('次の画面'))),
              )),
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    expect(find.text('次の画面'), findsOneWidget);
  }

  Future<void> swipeFromLeftEdge(WidgetTester tester) async {
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    final gesture = await tester.startGesture(Offset(5, size.height / 2));
    await gesture.moveBy(Offset(size.width * 0.3, 0));
    await gesture.moveBy(Offset(size.width * 0.4, 0));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  for (final platform in <TargetPlatform>[TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('${platform.name}: 左端からのスワイプで前の画面に戻る', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await pushPage(tester, fullscreenDialog: false);
        await swipeFromLeftEdge(tester);
        expect(find.text('次の画面'), findsNothing);
        expect(find.text('開く'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('fullscreenDialog (切り抜き画面) は端スワイプで戻らない', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pushPage(tester, fullscreenDialog: true);
      await swipeFromLeftEdge(tester);
      expect(find.text('次の画面'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // ビューアと同じく横スクロール (PageView) がある画面
  Widget pagerScreen({bool enabled = true}) => Scaffold(
        body: EdgeSwipeBack(
          label: '一覧に戻る',
          enabled: enabled,
          child: PageView(children: const <Widget>[
            Center(child: Text('次の画面')),
            Center(child: Text('2 ページ目')),
          ]),
        ),
      );

  testWidgets('PageView のある画面でも、左端の帯からのスワイプで戻る', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pushPage(tester, fullscreenDialog: false, page: pagerScreen());
      await swipeFromLeftEdge(tester);
      expect(find.text('開く'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('帯を無効にすると (手書き中) 端スワイプで戻らない', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pushPage(tester, fullscreenDialog: false, page: pagerScreen(enabled: false));
      await swipeFromLeftEdge(tester);
      expect(find.text('開く'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('引いている間は「一覧に戻る」が出て、手前で離すと戻らず引っ込む', (tester) async {
    await pushPage(tester, fullscreenDialog: false, page: pagerScreen());
    final indicator = find.byKey(const ValueKey<String>('edge-swipe-indicator'));
    expect(indicator, findsNothing);

    final gesture = await tester.startGesture(const Offset(5, 300));
    await gesture.moveBy(const Offset(40, 0)); // 戻れる距離 (96) の手前
    await tester.pump();
    expect(indicator, findsOneWidget);
    expect(find.text('一覧に戻る'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(indicator, findsNothing);
    expect(find.text('次の画面'), findsOneWidget, reason: '手前で離したら戻らない');

    // 戻れる位置まで引いて離すと戻る
    final g2 = await tester.startGesture(const Offset(5, 300));
    await g2.moveBy(const Offset(60, 0));
    await g2.moveBy(const Offset(60, 0));
    await tester.pump();
    await g2.up();
    await tester.pumpAndSettle();
    expect(find.text('開く'), findsOneWidget);
  });
}
