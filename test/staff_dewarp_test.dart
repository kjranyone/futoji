import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:futoji/services/staff_dewarp.dart';
import 'package:futoji/services/warper.dart';

const int _w = 1200;
const int _h = 1700;

/// まっすぐな楽譜 (五線 8 段 + 音符 + スラー) を描いた白黒画像。
/// 実際のページと同じく左右に余白を取る (五線が画像の端まであると、反りの最も
/// 急な端が短冊の検出範囲から外れ、変位場の端の延長ぶんが残差になる)。
Uint8List _flatScore({int staves = 8}) {
  final g = Uint8List(_w * _h)..fillRange(0, _w * _h, 235);
  void dot(int x, int y) {
    if (x >= 0 && x < _w && y >= 0 && y < _h) g[y * _w + x] = 30;
  }

  final rnd = math.Random(7);
  const sp = 11;
  for (int s = 0; s < staves; s++) {
    final top = 150 + s * 180;
    for (int k = 0; k < 5; k++) {
      for (int x = 120; x < _w - 80; x++) {
        dot(x, top + k * sp);
        dot(x, top + k * sp + 1);
      }
    }
    // 符頭 (塗りつぶし楕円) と符幹
    for (int n = 0; n < 24; n++) {
      final cx = 150 + n * 40 + rnd.nextInt(10);
      final cy = top + rnd.nextInt(5) * sp + (rnd.nextBool() ? sp ~/ 2 : 0);
      for (int dy = -5; dy <= 5; dy++) {
        for (int dx = -7; dx <= 7; dx++) {
          if (dx * dx / 49 + dy * dy / 25 <= 1) dot(cx + dx, cy + dy);
        }
      }
      for (int y = cy - 35; y < cy; y++) {
        dot(cx + 6, y);
      }
    }
    // スラー (五線と平行でない弧)
    for (int x = 200; x < 700; x++) {
      final y = top - 15 - (30 * math.sin(math.pi * (x - 200) / 500)).round();
      dot(x, y);
      dot(x, y + 1);
    }
  }
  return g;
}

/// ノド (左端) 側が反った形の湾曲をかける (tools/dewarp_staff.py の synth_curl と同じ形)。
Uint8List _curl(Uint8List src, {double amp = 0.035, double squeeze = 0.05}) {
  final out = Uint8List(_w * _h);
  for (int y = 0; y < _h; y++) {
    for (int x = 0; x < _w; x++) {
      final u = x / _w;
      final gg = math.pow(1 - u, 3).toDouble();
      final v = y / _h - 0.5;
      final sy = (y - amp * _h * gg * (0.4 + 1.2 * v)).clamp(0.0, _h - 1.0);
      final sx = (x + squeeze * _w * gg).clamp(0.0, _w - 1.0);
      out[y * _w + x] = src[sy.round() * _w + sx.round()];
    }
  }
  return out;
}

void main() {
  test('曲がった五線をまっすぐに戻す', () async {
    final curled = _curl(_flatScore());
    final before = StaffDewarp.detectLines(curled, _w, _h);
    expect(before.length, 40, reason: '五線 8 段 x 5 本');
    final b0 = StaffDewarp.bend(before);
    expect(b0, greaterThan(15));

    final dewarp = await StaffDewarp.estimate(curled, _w, _h);
    expect(dewarp, isNotNull);
    final out = dewarp!.remapGray(curled, _w, _h);
    final b1 = StaffDewarp.bend(StaffDewarp.detectLines(out, _w, _h));
    expect(b1, lessThan(3), reason: '補正前 $b0 px');
  });

  test('まっすぐな楽譜はほぼ動かさない', () async {
    final flat = _flatScore();
    final dewarp = await StaffDewarp.estimate(flat, _w, _h);
    if (dewarp != null) {
      for (int i = 0; i <= 10; i++) {
        for (int j = 0; j <= 10; j++) {
          final d = (dewarp.exactSourceY(i / 10, j / 10) - j / 10) * _h;
          expect(d.abs(), lessThan(1.5));
        }
      }
    }
  });

  test('短冊の走査を isolate で分けても 1 本で走査したときと同じ線になる', () async {
    final curled = _curl(_flatScore());
    final serial = StaffDewarp.detectLines(curled, _w, _h);
    for (final workers in const [2, 3, 8]) {
      final par = await StaffDewarp.detectLinesParallel(curled, _w, _h, workers);
      expect(par.length, serial.length, reason: 'workers=$workers');
      for (int i = 0; i < serial.length; i++) {
        expect(par[i].xs, serial[i].xs);
        expect(par[i].ys, serial[i].ys);
      }
    }
    final a = (await StaffDewarp.estimate(curled, _w, _h))!;
    final b = (await StaffDewarp.estimate(curled, _w, _h, workers: 4))!;
    expect(b.fields.length, a.fields.length);
    for (int i = 0; i < a.fields.length; i++) {
      expect(b.fields[i].coef, a.fields[i].coef);
    }
  });

  test('五線の無いページは補正しない', () async {
    // 白紙
    final blank = Uint8List(_w * _h)..fillRange(0, _w * _h, 240);
    expect(await StaffDewarp.estimate(blank, _w, _h), isNull);
    // 等間隔の罫線が続く表 (五線の外側が空いていない)
    final table = Uint8List(_w * _h)..fillRange(0, _w * _h, 240);
    for (int r = 0; r < 60; r++) {
      final y = 200 + r * 20;
      for (int x = 100; x < _w - 100; x++) {
        table[y * _w + x] = 30;
        table[(y + 1) * _w + x] = 30;
      }
    }
    expect(StaffDewarp.detectLines(table, _w, _h), isEmpty);
    expect(await StaffDewarp.estimate(table, _w, _h), isNull);
  });

  test('五線 1 段だけのページは x だけの変位で補正する', () async {
    final one = _curl(_flatScore(staves: 1));
    final dewarp = await StaffDewarp.estimate(one, _w, _h);
    expect(dewarp, isNotNull);
    expect(dewarp!.fields.first.degY, 0);
  });

  test('格子補間は厳密な写像とほぼ一致する', () async {
    final curled = _curl(_flatScore());
    final dewarp = (await StaffDewarp.estimate(curled, _w, _h))!;
    double worst = 0;
    for (int i = 0; i <= 37; i++) {
      for (int j = 0; j <= 53; j++) {
        final nx = i / 37, ny = j / 53;
        final e = (dewarp.sourceY(nx, ny) - dewarp.exactSourceY(nx, ny)).abs() * _h;
        worst = math.max(worst, e);
      }
    }
    expect(worst, lessThan(0.5));
  });

  test('台形補正に合成すると、台形補正 → 湾曲補正と同じ画像になる', () async {
    final curled = _curl(_flatScore());
    final dewarp = (await StaffDewarp.estimate(curled, _w, _h))!;
    final rgb = Uint8List(_w * _h * 3);
    for (int i = 0; i < _w * _h; i++) {
      rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = curled[i];
    }
    const quad = <Offset>[
      Offset(0, 0),
      Offset(_w * 1.0, 0),
      Offset(_w * 1.0, _h * 1.0),
      Offset(0, _h * 1.0),
    ];
    final out = warpPerspectiveRgb(
      src: rgb,
      srcW: _w,
      srcH: _h,
      numCh: 3,
      srcQuad: quad,
      outW: _w,
      outH: _h,
      dewarp: dewarp,
    );
    final gray = Uint8List(_w * _h);
    for (int i = 0; i < _w * _h; i++) {
      gray[i] = out[i * 3];
    }
    final b = StaffDewarp.bend(StaffDewarp.detectLines(gray, _w, _h));
    expect(b, lessThan(3));
  });
}
