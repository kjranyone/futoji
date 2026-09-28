import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:mymusicbook/services/detector.dart';

/// 暗い背景に明るい用紙を置いた合成画像で紙面検出を検証する。
void main() {
  // 点が凸四角形 (頂点順) の内側か (符号判定)
  bool inside(Offset p, List<Offset> q) {
    double cross(Offset a, Offset b) =>
        (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);
    final s = <double>[];
    for (int i = 0; i < 4; i++) {
      s.add(cross(q[i], q[(i + 1) % 4]));
    }
    return s.every((v) => v >= 0) || s.every((v) => v <= 0);
  }

  img.Image synthetic(int w, int h, List<Offset> paper) {
    final im = img.Image(width: w, height: h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = Offset(x.toDouble(), y.toDouble());
        if (inside(p, paper)) {
          // 用紙: 明るい白 + 模様 (譜線の代わりの縞) を入れても紙として抽出できるか
          final v = (y % 8 == 0) ? 210 : 245;
          im.setPixelRgb(x, y, v, v, v);
        } else {
          // 背景: 濃いグレー
          im.setPixelRgb(x, y, 35, 38, 42);
        }
      }
    }
    return im;
  }

  test('台形の用紙を検出できる', () {
    const paper = <Offset>[
      Offset(70, 50),
      Offset(330, 60),
      Offset(340, 250),
      Offset(60, 240),
    ];
    final im = synthetic(400, 300, paper);

    final quad = DocumentDetector.detect(im);
    expect(quad, isNotNull);
    final q = quad!;
    expect(q.length, 4);

    // 各検出コーナーが想定用紙の近くにあるか
    for (int i = 0; i < 4; i++) {
      final detected = Offset(q[i].dx * 400, q[i].dy * 300);
      double minDist = double.infinity;
      for (final c in paper) {
        minDist = (detected - c).distance < minDist ? (detected - c).distance : minDist;
      }
      expect(minDist, lessThan(12),
          reason: 'corner $i: $detected が用紙コーナーから遠い');
    }
  });

  test('軸平行の長方形を検出できる', () {
    const paper = <Offset>[
      Offset(100, 80),
      Offset(300, 80),
      Offset(300, 220),
      Offset(100, 220),
    ];
    final im = synthetic(400, 300, paper);
    final quad = DocumentDetector.detect(im);
    expect(quad, isNotNull);
    final q = quad!;
    // 正規化座標で ±0.04 以内
    final expected = <Offset>[
      const Offset(100 / 400, 80 / 300),
      const Offset(300 / 400, 80 / 300),
      const Offset(300 / 400, 220 / 300),
      const Offset(100 / 400, 220 / 300),
    ];
    for (int i = 0; i < 4; i++) {
      expect((q[i] - expected[i]).distance, lessThan(0.04),
          reason: 'corner $i');
    }
  });

  test('detectLuminance: 輝度配列から直接検出できる', () {
    const paper = <Offset>[
      Offset(100, 80),
      Offset(540, 80),
      Offset(540, 400),
      Offset(100, 400),
    ];
    final im = synthetic(640, 480, paper);
    // 輝度配列を直接組み立て (Y 平面を想定)
    final w = im.width;
    final h = im.height;
    final gray = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final px = im.getPixel(x, y);
        gray[y * w + x] = px.r.toInt();
      }
    }
    final quad = DocumentDetector.detectLuminance(gray, w, h);
    expect(quad, isNotNull);
    final expected = <Offset>[
      Offset(100 / 640, 80 / 480),
      Offset(540 / 640, 80 / 480),
      Offset(540 / 640, 400 / 480),
      Offset(100 / 640, 400 / 480),
    ];
    for (int i = 0; i < 4; i++) {
      final detected = quad![i];
      double minDist = 1.0;
      for (final e in expected) {
        final d = (detected - e).distance;
        if (d < minDist) minDist = d;
      }
      expect(minDist, lessThan(0.05), reason: 'corner $i: $detected');
    }
  });

  test('fillHoles: 穴埋めマスクは 0/255 で、穴が埋まる', () {
    final mask = Uint8List(300 * 400);
    // 紙 (ノイズ付きの穴含む) を 0..255 スケールで描く
    for (int y = 0; y < 300; y++) {
      for (int x = 0; x < 400; x++) {
        final v = x >= 100 && x <= 300 && y >= 80 && y <= 220;
        // 紙の内部に 1px の穴を多数作る (文字相当)
        mask[y * 400 + x] = v && (x % 3 == 0) ? 1 : (v ? 255 : 0);
      }
    }
    final filled = DocumentDetector.fillHoles(mask, 400, 300);
    // 穴が埋まっている (紙内部はすべて 255)
    for (int y = 90; y < 210; y += 7) {
      for (int x = 110; x < 290; x += 5) {
        expect(filled[y * 400 + x], 255, reason: '穴が残っている ($x,$y)');
      }
    }
    // 外周は 0
    expect(filled[0], 0);
    expect(filled[299 * 400 + 399], 0);
  });

  test('穴埋めマスクから直接四角形を検出できる (ネット経路)', () {
    // PaperNet の実経路: fillHoles 出力を detectLuminance に渡す
    final mask = Uint8List(400 * 300);
    for (int y = 0; y < 300; y++) {
      for (int x = 0; x < 400; x++) {
        final inPaper = x >= 100 && x <= 300 && y >= 80 && y <= 220;
        mask[y * 400 + x] = inPaper ? 255 : 0;
      }
    }
    // 文字相当の穴
    for (int y = 100; y < 200; y += 4) {
      for (int x = 120; x < 280; x += 6) {
        mask[y * 400 + x] = 0;
      }
    }
    final filled = DocumentDetector.fillHoles(mask, 400, 300);
    final quad = DocumentDetector.detectLuminance(filled, 400, 300);
    expect(quad, isNotNull, reason: '穴埋めした紙マスクからは四隅が出るべき');
    if (quad != null) {
      expect(quad[0].dx, closeTo(100 / 400, 0.05));
      expect(quad[0].dy, closeTo(80 / 300, 0.05));
    }
  });

  test('ネットマスク経路 (paperChecks:false) は境界ギザギザでも検出できる', () {
    // 実際のネット出力を模倣: 紙マスク + 境界の凹凸 + 散在ノイズ
    final mask = Uint8List(400 * 300);
    for (int y = 0; y < 300; y++) {
      for (int x = 0; x < 400; x++) {
        final inPaper = x >= 110 + (y % 7) * 2 && x <= 290 && y >= 90 && y <= 210;
        mask[y * 400 + x] = inPaper ? 255 : 0;
      }
    }
    // 周辺の散在誤検出
    for (int y = 20; y < 50; y += 2) {
      for (int x = 20; x < 60; x += 2) {
        mask[y * 400 + x] = 255;
      }
    }
    final filled = DocumentDetector.fillHoles(mask, 400, 300);
    final quad = DocumentDetector.detectLuminance(
        filled, 400, 300, paperChecks: false);
    expect(quad, isNotNull,
        reason: 'マスク経路ではエッジ支持検査をスキップするので検出できる');
  });

  test('snapQuadToEdges: 外れた四隅が実際の紙の縁にスナップされる', () {
    // 背景 60, 紙 (100,80)-(300,220) は 230 + 文字ノイズ
    final gray = Uint8List(400 * 300);
    for (int y = 0; y < 300; y++) {
      for (int x = 0; x < 400; x++) {
        final inPaper = x >= 100 && x <= 300 && y >= 80 && y <= 220;
        gray[y * 400 + x] =
            inPaper ? (230 - (x % 5) * 3).clamp(0, 255) : 60;
      }
    }
    // 初期四隅: 実際の紙より 10px 外側 (甘いアンカー)
    final loose = <Offset>[
      const Offset(90 / 400, 70 / 300),
      const Offset(310 / 400, 70 / 300),
      const Offset(310 / 400, 230 / 300),
      const Offset(90 / 400, 230 / 300),
    ];
    final snapped =
        DocumentDetector.snapQuadToEdges(loose, gray, 400, 300);
    // スナップ後は紙の縁 (±1.5% = ±6px/400px) 以内に収まる
    expect(snapped[0].dx, closeTo(100 / 400, 0.015));
    expect(snapped[0].dy, closeTo(80 / 300, 0.015));
    expect(snapped[2].dx, closeTo(300 / 400, 0.015));
    expect(snapped[2].dy, closeTo(220 / 300, 0.015));
  });

  test('snapQuadToEdges: 勾配がない場合は変化しない', () {
    final gray = Uint8List(400 * 300); // 全部 0
    final loose = <Offset>[
      const Offset(0.2, 0.2),
      const Offset(0.8, 0.2),
      const Offset(0.8, 0.8),
      const Offset(0.2, 0.8),
    ];
    final snapped = DocumentDetector.snapQuadToEdges(loose, gray, 400, 300);
    for (int i = 0; i < 4; i++) {
      expect(snapped[i], loose[i]);
    }
  });

  test('紙のない机のシーン (明背景+雑多物) では矩形を検出しない', () {
    // 実機で誤検出したケースの再現: 明るい机 + ケーブル + 機材、紙なし
    final im = img.Image(width: 400, height: 300);
    for (int y = 0; y < 300; y++) {
      for (int x = 0; x < 400; x++) {
        int v = 150 + ((x * 13 + y * 7) % 17) - 8; // 机の木目っぽいゆらぎ
        // 暗いケーブル (曲線の代わりに斜め帯)
        if ((x * 2 + y) % 53 < 5) v = 40 + ((x + y) % 20);
        // 濃い機材の矩形
        if (x > 250 && y > 180 && x < 340 && y < 260) v = 60;
        // 明るい機材 (モニタ脚など)
        if (x > 60 && x < 110 && y < 90) v = 190;
        im.setPixelRgb(x, y, v, v, (v * 0.95).toInt());
      }
    }
    final quad = DocumentDetector.detect(im);
    expect(quad, isNull, reason: '紙がないのに四隅を出してはいけない');
  });

  test('紙面がない (全体が単色) 場合は null または全面を返す', () {
    final im = img.Image(width: 200, height: 150);
    for (int y = 0; y < 150; y++) {
      for (int x = 0; x < 200; x++) {
        im.setPixelRgb(x, y, 90, 90, 90);
      }
    }
    final quad = DocumentDetector.detect(im);
    // 単色では二値化の前景比が極端になるため null が妥当
    expect(quad, isNull);
  });

  test('openMask: 細い首でつながったはみ出しを切り離し、本体は残す', () {
    const w = 100, h = 100;
    final mask = Uint8List(w * h);
    void fill(int x0, int y0, int x1, int y1) {
      for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
          mask[y * w + x] = 255;
        }
      }
    }

    fill(20, 20, 70, 80); // 紙の本体
    fill(70, 49, 90, 51); // 幅 2px の首
    fill(88, 40, 98, 60); // はみ出しの塊
    final opened = DocumentDetector.openMask(mask, w, h, 2);
    expect(opened[50 * w + 45], 255, reason: '本体は残る');
    expect(opened[50 * w + 80], 0, reason: '首は消える');
    expect(opened.every((v) => v == 0 || v == 255), isTrue);
    expect(DocumentDetector.openMask(mask, w, h, 0), same(mask));
  });

  test('辺の直線当てはめ: 斜めの四角形マスクの角を 1 画素未満で求める', () {
    const w = 256, h = 256;
    // 真の四隅 (連続座標, TL→TR→BR→BL)。わずかに回転・台形にする
    const truth = <Offset>[
      Offset(40.3, 30.7),
      Offset(214.6, 44.2),
      Offset(203.9, 228.5),
      Offset(31.2, 216.8),
    ];
    bool inside(double x, double y) {
      for (int i = 0; i < 4; i++) {
        final a = truth[i], b = truth[(i + 1) % 4];
        if ((b.dx - a.dx) * (y - a.dy) - (b.dy - a.dy) * (x - a.dx) < 0) {
          return false;
        }
      }
      return true;
    }

    final mask = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        if (inside(x + 0.5, y + 0.5)) mask[y * w + x] = 255;
      }
    }
    double maxErr(bool refine) {
      final q = DocumentDetector.detectLuminance(mask, w, h,
          workWidth: w, paperChecks: false, pad: 0, refineEdges: refine)!;
      var worst = 0.0;
      for (int i = 0; i < 4; i++) {
        worst = math.max(
            worst, (Offset(q[i].dx * w, q[i].dy * h) - truth[i]).distance);
      }
      return worst;
    }

    final refined = maxErr(true);
    expect(refined, lessThan(1.0));
    expect(refined, lessThan(maxErr(false)));
  });
}
