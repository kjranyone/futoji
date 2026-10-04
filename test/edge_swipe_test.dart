// 画面の左端からのスワイプで戻れること (Android でも)、
// 端の操作と競合する画面 (fullscreenDialog) では戻らないことを検証する。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mymusicbook/main.dart';
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
}
