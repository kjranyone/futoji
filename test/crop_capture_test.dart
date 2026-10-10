// 切り抜き画面で確定したときの学習データ保存 (TrainingCapture) を、
// 実際の CropScreen を動かして検証する。
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:image/image.dart' as img;
import 'package:futoji/screens/crop_screen.dart';
import 'package:futoji/services/quad_label.dart';
import 'package:futoji/services/training_capture.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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
  late File photo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('futoji_crop_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    Hive.init('${tmp.path}/hive');
    await Hive.openBox<dynamic>('settings');
    // 暗い机に白い紙 (横 1200 x 縦 900)
    final im = img.Image(width: 1200, height: 900);
    img.fill(im, color: img.ColorRgb8(40, 40, 40));
    img.fillRect(im,
        x1: 300, y1: 200, x2: 900, y2: 700, color: img.ColorRgb8(235, 235, 235));
    photo = File('${tmp.path}/photo.jpg')
      ..writeAsBytesSync(img.encodeJpg(im, quality: 90));
  });

  tearDown(() async {
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  // testWidgets は偽の時計で動くため、実 I/O (isolate でのデコード・ファイル保存) は
  // runAsync の中で実時間を進めて待ち、描画 (pump) はその外で行う。
  Future<void> openAndConfirm(WidgetTester tester) async {
    await tester.runAsync(() => tester.pumpWidget(
        MaterialApp(home: CropScreen(file: XFile(photo.path)))));
    for (int i = 0; i < 100; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '切り抜き画面の読み込みが終わらない');
    await tester.runAsync(() async {
      // タップを実時間側で行い、確定後の非同期保存を実 I/O で完了させる
      await tester.tap(find.byIcon(Icons.check_circle));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    });
    await tester.pump();
  }

  testWidgets('保存 ON: 確定すると表示画像と四隅がペアで保存される', (tester) async {
    await tester.runAsync(() => TrainingCapture.setEnabled(true));
    await openAndConfirm(tester);

    final dir = Directory('${tmp.path}/${TrainingCapture.dirName}');
    expect(dir.existsSync(), isTrue);
    final jsons = dir.listSync().where((e) => e.path.endsWith('.json')).toList();
    final jpgs = dir.listSync().where((e) => e.path.endsWith('.jpg')).toList();
    expect(jsons, hasLength(1));
    expect(jpgs, hasLength(1));

    final label = QuadLabel.fromJson(
        (jsonDecode(File(jsons.single.path).readAsStringSync()) as Map)
            .cast<String, Object?>());
    // 画像は切り抜き画面のワーク画像 (長辺 1000px) で、ラベルの寸法と一致する
    final saved = img.decodeJpg(File(jpgs.single.path).readAsBytesSync())!;
    expect(label.width, saved.width);
    expect(label.height, saved.height);
    expect(saved.width, 1000);
    expect(label.image, jpgs.single.uri.pathSegments.last);
    expect(label.corners, hasLength(4));
    // PC のテストではモデル (libonnxruntime.so) を読めず未検出 → 既定の四隅で確定
    // = 手で合わせた扱い
    expect(label.predicted, isNull);
    expect(label.edited, isTrue);
    expect(label.source, 'app_crop');
  });

  testWidgets('保存 OFF (既定): 何も保存しない', (tester) async {
    expect(TrainingCapture.enabled, isFalse);
    await openAndConfirm(tester);
    final dir = Directory('${tmp.path}/${TrainingCapture.dirName}');
    expect(dir.existsSync(), isFalse);
  });
}
