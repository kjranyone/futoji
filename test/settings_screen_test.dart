// 設定画面の開発者向けトグルと、自己診断が設定で止まることを検証する。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:futoji/screens/settings_screen.dart';
import 'package:futoji/services/self_test.dart';
import 'package:futoji/services/training_capture.dart';
import 'package:futoji/state/app_state.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getExternalStoragePath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('futoji_settings_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    Hive.init('${tmp.path}/hive');
    await Hive.openBox<dynamic>('settings');
  });

  tearDown(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  testWidgets('開発者向けトグルは既定 OFF で、タップで設定に保存される', (tester) async {
    expect(TrainingCapture.enabled, isFalse);
    expect(SelfTest.enabled, isFalse);

    // 全項目が 1 画面に収まる大きさにする (下の方の開発者向けトグルもタップできるように)
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = AppState();
    expect(app.aiSharpen, isFalse);
    expect(app.continuousFocus, isFalse, reason: '既定はタップでピント (合わせ続けない)');
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: const MaterialApp(home: SettingsScreen()),
    ));
    expect(find.text('このアプリについて'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('検出改善用に切り抜き結果を保存'));
      await tester.tap(find.text('紙面検出の自己診断を許可'));
      await tester.tap(find.text('AI でくっきり'));
      await tester.tap(find.text('ピントを合わせ続ける'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(TrainingCapture.enabled, isTrue);
    expect(SelfTest.enabled, isTrue);
    expect(app.aiSharpen, isTrue);
    expect(app.continuousFocus, isTrue);
    final switches = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile));
    expect(switches.every((s) => s.value), isTrue);
  });

  test('自己診断が OFF なら目印があっても実行せず、目印も残す', () async {
    final dir = Directory('${tmp.path}/selftest')..createSync(recursive: true);
    final marker = File('${dir.path}/RUN')..writeAsStringSync('token-1');

    await SelfTest.runIfRequested();

    expect(marker.existsSync(), isTrue);
    expect(File('${dir.path}/result.json').existsSync(), isFalse);
  });
}
