// 「このアプリについて」: バージョン表示とプライバシーポリシーの全文表示。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futoji/screens/about_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Futoji',
      packageName: 'com.kjranyone.futoji',
      version: '1.0.0',
      buildNumber: '3000',
      buildSignature: '',
    );
  });

  testWidgets('アプリ名・バージョン・各項目を表示し、プライバシーポリシーを開ける', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: AboutScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Futoji'), findsOneWidget);
    expect(find.text('バージョン 1.0.0 (3000)'), findsOneWidget);
    expect(find.text('オープンソースライセンス'), findsOneWidget);
    expect(find.text(AboutScreen.sourceUrl), findsOneWidget);

    await tester.tap(find.text('プライバシーポリシー'));
    await tester.pumpAndSettle();
    // 同梱した docs/PRIVACY_POLICY.md の見出しと表 (カード表示) が出る
    expect(find.text('Futoji プライバシーポリシー'), findsOneWidget);
    expect(find.text('1. 収集する情報'), findsOneWidget);
    expect(find.textContaining('カメラで撮影した画像'), findsWidgets);
  });

  testWidgets('段落の改行はつなげ、箇条書きの続きの行は同じ項目にまとめる', (tester) async {
    const md = '''# 題

一行目の文が
次の行に続く。

- 項目の文が
  続きの行にわたる
- 二つ目
''';
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => ListView(children: buildSimpleMarkdown(context, md))),
    ));
    expect(find.text('題'), findsOneWidget);
    expect(find.text('一行目の文が次の行に続く。', findRichText: true), findsOneWidget);
    expect(find.text('項目の文が続きの行にわたる', findRichText: true), findsOneWidget);
    expect(find.text('二つ目', findRichText: true), findsOneWidget);
  });
}
