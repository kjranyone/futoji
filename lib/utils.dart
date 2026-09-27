/// epoch ミリ秒 → '2026/09/24 14:30' 形式。
String formatDateTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String p(int v) => v.toString().padLeft(2, '0');
  return '${d.year}/${p(d.month)}/${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
}
