import 'dart:math';

/// UUID 依存を避けた簡易 ID 生成 (時刻 + 乱数、base36)。
String newId() {
  final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rnd = Random().nextInt(0x7FFFFFFF).toRadixString(36);
  return '$ts$rnd';
}
