// 押している間だけ縮むボタン (カメラのシャッター) と、
// 浮かせて出す SnackBar (シャッターに被せない) を検証する。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:futoji/widgets/dialogs.dart';
import 'package:futoji/widgets/press_scale.dart';

void main() {
  testWidgets('押している間は縮み、離すと戻って onTap と振動が 1 回ずつ', (tester) async {
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add('${call.arguments}');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: PressScale(
          onTap: () => taps++,
          scale: 0.9,
          child: const SizedBox(width: 80, height: 80),
        ),
      ),
    ));
    double scale() => tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
    expect(scale(), 1);

    final g = await tester.startGesture(tester.getCenter(find.byType(PressScale)));
    await tester.pump();
    expect(scale(), 0.9, reason: '触れた瞬間に沈む');

    await g.up();
    await tester.pumpAndSettle();
    expect(scale(), 1);
    expect(taps, 1);
    expect(haptics, hasLength(1));
  });

  testWidgets('無効 (onTap が null) のときは沈まない', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(
        child: PressScale(onTap: null, child: SizedBox(width: 80, height: 80)),
      ),
    ));
    final g = await tester.startGesture(tester.getCenter(find.byType(PressScale)));
    await tester.pump();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('bottomMargin を渡した SnackBar は下から浮いて出る', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showSnackBar(context, '保存しました', bottomMargin: 130),
              child: const Text('出す'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('出す'));
    await tester.pumpAndSettle();
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    // SnackBar 自体は余白込みの大きさなので、見えている板 (Material) を測る
    final bar = tester.getRect(find
        .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
        .first);
    expect(bar.bottom, closeTo(size.height - 130, 1));
    expect(bar.left, closeTo(16, 1));
    // 時間切れで消えるまで待つ (未処理のタイマーを残さない)
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
