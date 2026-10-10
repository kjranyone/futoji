// カメラ画面の向き固定 (ライブ枠の座標変換が縦向き前提のため) を検証する。
// 実機のカメラは使えないので、カメラ権限を「拒否」にして画面を開き、
// SystemChrome.setPreferredOrientations の呼び出しを確かめる。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futoji/models/music_document.dart';
import 'package:futoji/screens/camera_screen.dart';

void main() {
  testWidgets('カメラ画面の間だけ縦向きに固定し、閉じると解除する', (tester) async {
    final orientationCalls = <Object?>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        orientationCalls.add(call.arguments);
      }
      return null;
    });
    // permission_handler: カメラ (1) を拒否 (0) にする → カメラを初期化しない
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (call) async => call.method == 'requestPermissions'
            ? <int, int>{1: 0}
            : null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/permissions/methods'), null);
    });

    final doc = MusicDocument(
      id: 'd1',
      title: 'テスト',
      createdAt: 0,
      updatedAt: 0,
    );
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => CameraScreen(document: doc))),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(orientationCalls, isNotEmpty, reason: '開いたときに向きを指定すること');
    expect(orientationCalls.first, <String>['DeviceOrientation.portraitUp']);
    expect(find.text('カメラの利用が許可されていません'), findsOneWidget);

    // 閉じると向き指定を解除 (空リスト = アプリ既定) する
    Navigator.of(tester.element(find.byType(CameraScreen))).pop();
    await tester.pumpAndSettle();
    expect(orientationCalls.last, <String>[]);
  });
}
