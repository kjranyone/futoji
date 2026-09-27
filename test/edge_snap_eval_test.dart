// 実キャプチャ + BiRefNet 教師マスクを使った snapQuadToEdges の定量評価。
// 単体テストというより評価ハーネス: 教師四隅を外側へ膨らませて
// 「甘いアンカー」を再現し、スナップが実際の紙の縁へ引き戻せるか測る。
// 角座標はすべて写真のピクセル空間で扱う。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mymusicbook/services/detector.dart';

const maskPad = 0.02; // detectLuminance が内包する外側パディング (画像短辺比)

// BiRefNet マスクが紙と一致しないため GT に使えない実キャプチャ:
// - CAP3559555545420765940: チラシとウェブカメラが 1 マスクに癒合
// - CAP7457501899405073292: 紙なし (ウェブカメラのみ。紙なしネガティブサンプル)
const invalidGt = {
  'CAP3559555545420765940.jpg',
  'CAP7457501899405073292.jpg',
};

void main() {
  final dir = Directory('training_data/real_captures');
  test('edge snap eval on real captures',
      // training_data はリポジトリ外 (.gitignore) なので、無い環境ではスキップ
      skip: dir.existsSync() ? false : 'training_data/real_captures がありません',
      timeout: const Timeout(Duration(minutes: 5)), () async {
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jpg'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty);

    final rng = math.Random(42);
    final errsBefore = <List<double>>[[], [], []];
    final errsAfter = <List<double>>[[], [], []];
    final deltas = const [0.01, 0.02, 0.03];
    var wins = 0, total = 0;

    for (final f in files) {
      final name = f.uri.pathSegments.last;
      if (invalidGt.contains(name)) continue;
      final maskFile = File(
          'training_data/real_captures/masks/${name.replaceAll('.jpg', '')}_mask.png');
      if (!maskFile.existsSync()) continue;

      final photo = img.bakeOrientation(img.decodeJpg(f.readAsBytesSync())!);
      final mask = img.decodePng(maskFile.readAsBytesSync())!;

      // 教師四隅: マスクを検出 → 内包パディングを打ち消して縮小
      final maskGray = DocumentDetector.toGray(mask);
      final gtRaw = DocumentDetector.detectLuminance(
          maskGray, mask.width, mask.height,
          workWidth: 320, paperChecks: false);
      if (gtRaw == null) {
        stdout.writeln('$name: GT quad null, skip');
        continue;
      }
      final gtN = shrinkTowardCentroid(gtRaw, maskPad);

      // 写真輝度 (長辺 1024 に縮小 — 端末の検出ストリームと同程度)
      final (photoGray, pw, ph) = grayCapped(photo, 1024);
      final minSide = math.min(pw, ph).toDouble();
      final gt = <Offset>[for (final c in gtN) Offset(c.dx * pw, c.dy * ph)];

      for (int di = 0; di < deltas.length; di++) {
        final delta = deltas[di];
        // 甘いアンカーを再現: 外側へ delta*minSide + 角ごとのジッタ
        final jittered = <Offset>[
          for (final c in inflate(gt, delta * minSide))
            c +
                Offset((rng.nextDouble() - 0.5) * 0.008 * minSide,
                    (rng.nextDouble() - 0.5) * 0.008 * minSide),
        ];
        final snapped = DocumentDetector.snapQuadToEdges(
            <Offset>[for (final c in jittered) Offset(c.dx / pw, c.dy / ph)],
            photoGray,
            pw,
            ph);
        final snappedPx = <Offset>[
          for (final c in snapped) Offset(c.dx * pw, c.dy * ph)
        ];

        final eb = meanCornerDist(jittered, gt) / minSide;
        final ea = meanCornerDist(snappedPx, gt) / minSide;
        errsBefore[di].add(eb);
        errsAfter[di].add(ea);
        total++;
        if (ea <= eb + 1e-6) wins++;
        stdout.writeln('$name d=$delta  before=${(eb * 100).toStringAsFixed(2)}%  '
            'after=${(ea * 100).toStringAsFixed(2)}%  '
            '${ea <= eb ? 'OK' : 'WORSE'}');
      }
    }

    double median(List<double> v) {
      final s = List.of(v)..sort();
      return s[s.length ~/ 2];
    }

    final allBefore = [for (final v in errsBefore) ...v];
    final allAfter = [for (final v in errsAfter) ...v];
    stdout.writeln('---');
    stdout.writeln('cases=$total  improved(strict)=$wins');
    for (int di = 0; di < deltas.length; di++) {
      stdout.writeln('d=${deltas[di]}  median before='
          '${(median(errsBefore[di]) * 100).toStringAsFixed(2)}%  '
          'after=${(median(errsAfter[di]) * 100).toStringAsFixed(2)}%');
    }
    stdout.writeln('all median before=${(median(allBefore) * 100).toStringAsFixed(2)}%  '
        'after=${(median(allAfter) * 100).toStringAsFixed(2)}%');

    // 大きなズレは確実に縮み、小さなズレは悪化しないこと
    expect(median(errsAfter[2]), lessThan(median(errsBefore[2]) * 0.7));
    expect(median(errsAfter[0]), lessThan(median(errsBefore[0]) * 1.15));
  });
}

/// _padCorners (detectLuminance 内部) の逆操作: 各角を重心へ ratio (短辺比) だけ戻す。
List<Offset> shrinkTowardCentroid(List<Offset> q, double ratio) {
  final c = centroid(q);
  final amount = ratio * shortSide(q);
  return <Offset>[
    for (final p in q)
      () {
        final vx = p.dx - c.dx;
        final vy = p.dy - c.dy;
        final len = math.sqrt(vx * vx + vy * vy).clamp(1e-6, double.infinity);
        return Offset(c.dx + vx / len * (len - amount),
            c.dy + vy / len * (len - amount));
      }(),
  ];
}

/// 各角を重心から amount ピクセルだけ外側へ膨らませる。
List<Offset> inflate(List<Offset> q, double amount) {
  final c = centroid(q);
  return <Offset>[
    for (final p in q)
      () {
        final vx = p.dx - c.dx;
        final vy = p.dy - c.dy;
        final len = math.sqrt(vx * vx + vy * vy).clamp(1e-6, double.infinity);
        return Offset(c.dx + vx / len * (len + amount),
            c.dy + vy / len * (len + amount));
      }(),
  ];
}

Offset centroid(List<Offset> q) {
  var cx = 0.0, cy = 0.0;
  for (final p in q) {
    cx += p.dx;
    cy += p.dy;
  }
  return Offset(cx / 4, cy / 4);
}

double shortSide(List<Offset> q) =>
    math.min(qWidth(q), qHeight(q));
double qWidth(List<Offset> q) =>
    q.map((p) => p.dx).reduce(math.max) - q.map((p) => p.dx).reduce(math.min);
double qHeight(List<Offset> q) =>
    q.map((p) => p.dy).reduce(math.max) - q.map((p) => p.dy).reduce(math.min);

double meanCornerDist(List<Offset> a, List<Offset> b) {
  var s = 0.0;
  for (int i = 0; i < 4; i++) {
    s += (a[i] - b[i]).distance;
  }
  return s / 4;
}

(Uint8List, int, int) grayCapped(img.Image source, int cap) {
  var im = source;
  final long = math.max(im.width, im.height);
  if (long > cap) {
    im = im.width >= im.height
        ? img.copyResize(im, width: cap, interpolation: img.Interpolation.average)
        : img.copyResize(
            im, height: cap, interpolation: img.Interpolation.average);
  }
  return (DocumentDetector.toGray(im), im.width, im.height);
}
