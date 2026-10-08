// 曲がり補正 (lib/services/staff_dewarp.dart) の評価ハーネス。
//
// tools/dewarp_staff.py と同じ条件・同じ指標で、Python 試作と数値を突き合わせる:
//   - 四隅ラベルで台形補正 (幅 1200px) した画像に補正をかける
//   - それに既知の湾曲 (ノド側が反る形, 左 / 右) をかけた合成でも試す
//   - 指標 = 検出した各線の曲がり (3 次の当てはめ曲線の max - min, px) の中央値
//
// 実行:
//   flutter test test/staff_dewarp_eval_test.dart
// 環境変数:
//   DEWARP_EVAL_DIR  評価データ (training_data/eval_hard)。<id>.jpg + <id>.json (QuadLabel)
//   DEWARP_PASSES    推定の反復回数 (既定はアプリと同じ)
//   DEWARP_WORKERS   短冊の走査を分ける isolate 数 (既定 1)
//
// データが無い環境ではスキップする。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mymusicbook/services/quad_label.dart';
import 'package:mymusicbook/services/staff_dewarp.dart';
import 'package:mymusicbook/services/warper.dart';

String _env(String key, String fallback) =>
    Platform.environment[key]?.trim().isNotEmpty == true
        ? Platform.environment[key]!.trim()
        : fallback;

/// tools/dewarp_staff.py の synth_curl と同じ形の湾曲 (双一次補間)。
Uint8List _curl(Uint8List src, int w, int h,
    {required double amp, double squeeze = 0.05, required bool spineLeft}) {
  final out = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final u = spineLeft ? x / w : 1 - x / w;
      final g = math.pow(1 - u, 3).toDouble();
      final v = y / h - 0.5;
      final sy = (y - amp * h * g * (0.4 + 1.2 * v)).clamp(0.0, h - 1.0);
      final sx = (x + (spineLeft ? 1 : -1) * squeeze * w * g).clamp(0.0, w - 1.0);
      final x0 = sx.floor(), y0 = sy.floor();
      final x1 = math.min(x0 + 1, w - 1), y1 = math.min(y0 + 1, h - 1);
      final fx = sx - x0, fy = sy - y0;
      out[y * w + x] = (src[y0 * w + x0] * (1 - fx) * (1 - fy) +
              src[y0 * w + x1] * fx * (1 - fy) +
              src[y1 * w + x0] * (1 - fx) * fy +
              src[y1 * w + x1] * fx * fy)
          .round();
    }
  }
  return out;
}

void main() {
  final dir = Directory(_env('DEWARP_EVAL_DIR', 'training_data/eval_hard'));
  final passes = int.tryParse(_env('DEWARP_PASSES', ''));
  final workers = int.tryParse(_env('DEWARP_WORKERS', '')) ?? 1;
  final labels = dir.existsSync()
      ? (dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  test('staff dewarp eval', skip: labels.isEmpty ? '評価データがありません: ${dir.path}' : false,
      timeout: const Timeout(Duration(minutes: 20)), () async {
    final rows = <(String, int, double, double, bool, int)>[];
    for (final lf in labels) {
      final label = QuadLabel.fromJson(
          (jsonDecode(lf.readAsStringSync()) as Map).cast<String, Object?>());
      final corners = label.corners;
      if (corners == null) continue;
      final decoded = img.decodeJpg(File('${dir.path}/${label.image}').readAsBytesSync())!;
      final quad = <Offset>[
        for (final c in corners) Offset(c.dx * decoded.width, c.dy * decoded.height),
      ];
      final size = outputSizeForQuad(quad);
      const w = StaffDewarp.workWidth;
      final h = (size.height * w / size.width).round();
      // アプリと同じく、台形補正と輝度化を 1 回で行う
      final flat = warpPerspectiveGray(
        src: decoded.getBytes(),
        srcW: decoded.width,
        srcH: decoded.height,
        numCh: decoded.numChannels,
        srcQuad: quad,
        outW: w,
        outH: h,
      );
      final stem = label.image.replaceAll('.jpg', '');
      final cases = <String, Uint8List>{
        stem: flat,
        '${stem}_curlL': _curl(flat, w, h, amp: 0.035, spineLeft: true),
        '${stem}_curlR': _curl(flat, w, h, amp: 0.05, spineLeft: false),
      };
      for (final MapEntry(key: name, value: gray) in cases.entries) {
        final sw = Stopwatch()..start();
        final lines = StaffDewarp.detectLines(gray, w, h);
        final dewarp = passes == null
            ? await StaffDewarp.estimate(gray, w, h, workers: workers)
            : await StaffDewarp.estimate(gray, w, h, passes: passes, workers: workers);
        final ms = sw.elapsedMilliseconds;
        final out = dewarp == null ? gray : dewarp.remapGray(gray, w, h);
        final b0 = StaffDewarp.bend(lines);
        final b1 = StaffDewarp.bend(StaffDewarp.detectLines(out, w, h));
        rows.add((name, lines.length, b0, b1, dewarp != null, ms));
      }
    }

    final buf = StringBuffer()
      ..writeln('${'case'.padRight(22)}${'lines'.padLeft(6)}${'before'.padLeft(9)}'
          '${'after'.padLeft(8)}  fitted     ms');
    for (final r in rows) {
      buf.writeln('${r.$1.padRight(22)}${'${r.$2}'.padLeft(6)}'
          '${r.$3.toStringAsFixed(1).padLeft(9)}${r.$4.toStringAsFixed(1).padLeft(8)}'
          '  ${r.$5 ? 'yes' : 'no '}  ${'${r.$6}'.padLeft(6)}');
    }
    double median(List<double> v) {
      final s = [...v]..sort();
      return s.isEmpty ? double.nan : s[s.length ~/ 2];
    }

    for (final (kind, synth) in const [('実写', false), ('合成', true)]) {
      final r = rows.where((e) => e.$1.contains('_curl') == synth).toList();
      final ok = r.where((e) => e.$5).toList();
      buf.writeln('$kind: ${r.length} 件中 ${ok.length} 件を補正 / '
          '補正前 ${median([for (final e in ok) e.$3]).toStringAsFixed(1)} px → '
          '補正後 ${median([for (final e in ok) e.$4]).toStringAsFixed(1)} px (中央値)');
    }
    buf.writeln('推定時間 (PC, JIT) 中央値: '
        '${median([for (final e in rows) e.$6.toDouble()]).toStringAsFixed(0)} ms');
    // ignore: avoid_print
    print(buf);

    // 補正した場合は必ず曲がりが減っている (安全策が効いている)
    for (final r in rows.where((e) => e.$5)) {
      expect(r.$4, lessThan(r.$3), reason: r.$1);
    }
    expect(median([for (final e in rows.where((e) => e.$5)) e.$4]), lessThan(3));
  });
}
