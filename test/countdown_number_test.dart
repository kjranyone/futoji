// 自動撮影のカウントダウン表示 (3 → 2 → 1) とライブ枠の色。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mymusicbook/screens/camera_screen.dart';

void main() {
  test('進み 0..1 を 3 → 2 → 1 に分ける', () {
    expect(countdownNumber(0), 3);
    expect(countdownNumber(0.32), 3);
    expect(countdownNumber(0.34), 2);
    expect(countdownNumber(0.66), 2);
    expect(countdownNumber(0.67), 1);
    expect(countdownNumber(1.0), 1, reason: '撮影直前も 0 にはしない');
  });

  test('枠の色: 探索中は白、カウントダウン中は緑、撮影済みは青', () {
    expect(const LiveOverlay().color, Colors.white70);
    expect(const LiveOverlay(phase: LivePhase.countdown).color, const Color(0xFF4CAF50));
    expect(const LiveOverlay(phase: LivePhase.captured).color, const Color(0xFF42A5F5));
  });
}
