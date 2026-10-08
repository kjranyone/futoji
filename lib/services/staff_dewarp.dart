import 'dart:math' as math;
import 'dart:typed_data';

/// 五線を手がかりにした紙面の湾曲補正 (本のノド付近の反りなど)。
///
/// 台形補正 (warper.dart のホモグラフィ) は平面の傾きしか直せない。楽譜の五線は
/// 「本来まっすぐ水平・等間隔」なので、台形補正後の画像で五線を検出し、
/// その曲がりから縦方向の変位場 D(x, y) を推定する。補正後の (x, y) は
/// 補正前の (x, y + D(x, y)) から画素を取る。
///
/// tools/dewarp_staff.py の移植 (検証・評価は Python 側と同じ指標で
/// test/staff_dewarp_eval_test.dart から行う)。
///
/// 横方向の縮み (ノド付近の圧縮) は扱わない。五線が見つからないページや、
/// 推定が怪しいとき (下記の安全策) は null を返し、補正しない。
class StaffDewarp {
  StaffDewarp._();

  /// 検出に使う画像の幅。しきい値類はこの幅で調整してある。
  static const int workWidth = 1200;

  /// 五線の線がこれ未満のページは補正しない (= 五線 1 段ぶん)。
  static const int minLines = 5;

  /// 変位場の x 方向の次数 (ノド際の急な曲がりに追いつくため 6)。
  static const int degX = 6;

  /// 変位場の y 方向の次数。
  static const int degY = 2;

  /// 推定する。[gray] は台形補正済みのグレースケール (幅 [workWidth] 前後)。
  ///
  /// 検出 → 当てはめを 2 回繰り返す (急な曲がりは 1 回では拾い切れないため)。
  /// 各回とも、補正後に検出し直して曲がりが 2 割以上減らなければ、その回は捨てる。
  static PageDewarp? estimate(Uint8List gray, int w, int h, {int passes = 2}) {
    final fields = <StaffField>[];
    var cur = gray;
    var lines = detectLines(cur, w, h);
    for (int pass = 0; pass < passes; pass++) {
      final field = fitField(lines, w, h);
      if (field == null) break;
      final next = PageDewarp(<StaffField>[...fields, field]);
      final nxt = next.remapGray(gray, w, h);
      final nextLines = detectLines(nxt, w, h);
      // NaN (線が無い) との比較は false になり、補正を捨てる側に倒れる
      if (!(bend(nextLines) < 0.8 * bend(lines))) break;
      fields.add(field);
      cur = nxt;
      lines = nextLines;
    }
    return fields.isEmpty ? null : PageDewarp(fields);
  }

  // ------------------------------------------------------------------ 検出

  /// 五線を検出し、線ごとの点列を返す (五線 1 段につき 5 本)。
  ///
  /// 1. 縦の短冊 (幅 ~W/24、半分ずつ重ねる) ごとに、傾きを振って横投影し最も鋭い投影をとる
  /// 2. 投影上で「sp 間隔で 5 本そろい、間と外側 (±3 間隔) は空いている」櫛を五線とする
  ///    (スラー・連桁は櫛にならず、表の罫線は外側が空いていないので落ちる)
  /// 3. 短冊間を左から右へ、傾きで予測した y の近い五線どうしでつなぐ
  /// 4. 同じ五線に重なったトラックは長いほうを残し、横幅の 1/4 以上・
  ///    範囲内の短冊の半分以上で見つかった五線だけを採用する
  static List<StaffLine> detectLines(Uint8List gray, int w, int h) {
    final ink = _adaptiveInk(gray, w, h);
    final (t, sp) = _staffMetrics(ink, w, h);
    // 列ごとに連続したメモリにしておく (投影の内側ループを速くするため)
    final inkT = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      final row = y * w;
      for (int x = 0; x < w; x++) {
        inkT[x * h + y] = ink[row + x];
      }
    }
    final sw = math.max(40, w ~/ 24);
    final step = sw ~/ 2;
    const nSlopes = 17;
    final lo = <int>[for (int k = -2; k <= 2; k++) (k * sp).round()];
    final go = <int>[for (final g in const [-1.5, -0.5, 0.5, 1.5]) (g * sp).round()];
    final oo = (3 * sp).round();
    final thr = 0.35 * sw * t;
    final dets = <_Det>[];
    final p = Float64List(h);
    final best = Float64List(h);
    final pb = Float64List(h);
    final pm = Float64List(h);
    final comb = Float64List(h);
    for (int x0 = 0; x0 + sw <= w; x0 += step) {
      // 1. 傾きを振った投影のうち、最も鋭い (二乗和が最大の) もの。
      //    -0.2..0.2 を 0.025 刻み (17 通り) の格子で、粗密に探す
      //    (0.1 刻みの 5 通り → ±0.05 → ±0.025。全通りの約半分の計算で済む)
      final xc = (sw - 1) / 2;
      final scores = Float64List(nSlopes)..fillRange(0, nSlopes, -1);
      double bestScore = -1;
      int bestSi = nSlopes ~/ 2;
      void tryslope(int si) {
        if (si < 0 || si >= nSlopes || scores[si] >= 0) return;
        final s = -0.2 + 0.4 * si / (nSlopes - 1);
        p.fillRange(0, h, 0);
        for (int x = 0; x < sw; x++) {
          final sh = (s * (x - xc)).round() % h;
          final base = (x0 + x) * h;
          // p[y] += ink[(y + sh) mod h]
          final split = h - sh;
          for (int y = 0; y < split; y++) {
            p[y] += inkT[base + y + sh];
          }
          for (int y = split; y < h; y++) {
            p[y] += inkT[base + y + sh - h];
          }
        }
        double score = 0;
        for (int y = 0; y < h; y++) {
          score += p[y] * p[y];
        }
        scores[si] = score;
        if (score > bestScore || (score == bestScore && si < bestSi)) {
          bestScore = score;
          bestSi = si;
          best.setAll(0, p);
        }
      }

      for (int si = 0; si < nSlopes; si += 4) {
        tryslope(si);
      }
      for (final step in const [2, 1]) {
        final c = bestSi;
        tryslope(c - step);
        tryslope(c + step);
      }
      final bestSlope = -0.2 + 0.4 * bestSi / (nSlopes - 1);
      // 線の太さぶんをまとめる (箱フィルタの和)
      final k = t + 1;
      final anchor = k ~/ 2;
      for (int y = 0; y < h; y++) {
        double acc = 0;
        for (int i = 0; i < k; i++) {
          acc += best[_reflect101(y - anchor + i, h)];
        }
        pb[y] = acc;
      }
      // ±1px の揺れを許す
      for (int y = 0; y < h; y++) {
        pm[y] = math.max(pb[(y - 1 + h) % h], math.max(pb[y], pb[(y + 1) % h]));
      }
      // 2. 櫛のスコア
      for (int y = 0; y < h; y++) {
        comb[y] = 0;
        if (y + lo[0] < 0 || y + lo[4] >= h) continue;
        double lmin = double.infinity, lsum = 0;
        for (final o in lo) {
          final v = pm[y + o];
          lsum += v;
          if (v < lmin) lmin = v;
        }
        final lmean = lsum / 5;
        double gsum = 0;
        for (final o in go) {
          gsum += pb[(y + o).clamp(0, h - 1)];
        }
        final gmean = gsum / 4;
        final ov = math.max(pm[(y - oo).clamp(0, h - 1)], pm[(y + oo).clamp(0, h - 1)]);
        if (gmean < lmean / 3 && ov < lmean / 2) {
          comb[y] = math.min(lmin, lmean - gmean);
        }
      }
      // しきい値を超えた行だけを、スコアの高い順に
      final order = <int>[
        for (int y = 0; y < h; y++)
          if (comb[y] >= thr) y,
      ]..sort((a, b) => comb[b].compareTo(comb[a]));
      final taken = Uint8List(h);
      for (final yc in order) {
        if (comb[yc] < thr) break;
        if (taken[yc] != 0) continue;
        final a = math.max(0, (yc - 2.5 * sp).truncate());
        final b = math.min(h, (yc + 2.5 * sp).truncate() + 1);
        taken.fillRange(a, b, 1);
        // 各線を ±t の範囲で投影の重心に寄せる
        final ys = Float64List(5);
        for (int kk = 0; kk < 5; kk++) {
          final c = (yc + (kk - 2) * sp).round();
          final ra = math.max(0, c - t - 1), rb = math.min(h, c + t + 2);
          double ws = 0, wy = 0;
          for (int y = ra; y < rb; y++) {
            ws += pb[y];
            wy += pb[y] * y;
          }
          ys[kk] = wy / math.max(ws, 1e-6);
        }
        dets.add(_Det(x0 + (sw - 1) / 2, bestSlope, ys));
      }
    }

    // 3. 短冊をまたいでつなぐ (dets は x の昇順に並んでいる)
    final tracks = <List<_Det>>[];
    for (final d in dets) {
      List<_Det>? bestTr;
      double bd = 0.8 * sp;
      for (final tr in tracks) {
        final l = tr.last;
        if (l.x >= d.x || d.x - l.x > 4 * sw) continue;
        final pred = l.ys[2] + 0.5 * (l.slope + d.slope) * (d.x - l.x);
        final e = (pred - d.ys[2]).abs();
        if (e < bd) {
          bestTr = tr;
          bd = e;
        }
      }
      if (bestTr == null) {
        tracks.add(<_Det>[d]);
      } else {
        bestTr.add(d);
      }
    }

    // 4. 同じ五線の上に重なったトラック (検出が 1 本ずれた区間) は長いほうを残す
    final byLen = List<int>.generate(tracks.length, (i) => i)
      ..sort((a, b) {
        final c = tracks[b].length.compareTo(tracks[a].length);
        return c != 0 ? c : a.compareTo(b);
      });
    final kept = <List<_Det>>[];
    for (final i in byLen) {
      final tr = tracks[i];
      var dup = false;
      for (final k in kept) {
        final lo2 = math.max(tr.first.x, k.first.x);
        final hi2 = math.min(tr.last.x, k.last.x);
        if (hi2 < lo2) continue;
        final mid = (lo2 + hi2) / 2;
        if ((_interpMid(tr, mid) - _interpMid(k, mid)).abs() < 2.5 * sp) {
          dup = true;
          break;
        }
      }
      if (!dup) kept.add(tr);
    }
    final lines = <StaffLine>[];
    for (final tr in kept) {
      final span = tr.last.x - tr.first.x;
      if (span < 0.25 * w || tr.length < 0.5 * (span / step + 1)) continue;
      final xs = Float64List.fromList(<double>[for (final d in tr) d.x]);
      for (int k = 0; k < 5; k++) {
        lines.add(StaffLine(xs, Float64List.fromList(<double>[for (final d in tr) d.ys[k]])));
      }
    }
    return lines;
  }

  /// 適応二値化 (31x31 の局所平均 - 12 以下をインク)。cv2.adaptiveThreshold 相当。
  static Uint8List _adaptiveInk(Uint8List gray, int w, int h) {
    const r = 15;
    final integ = Int64List((w + 1) * (h + 1));
    for (int y = 0; y < h; y++) {
      int rowSum = 0;
      final o = (y + 1) * (w + 1);
      final po = y * (w + 1);
      for (int x = 0; x < w; x++) {
        rowSum += gray[y * w + x];
        integ[o + x + 1] = integ[po + x + 1] + rowSum;
      }
    }
    final ink = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      final y0 = math.max(0, y - r), y1 = math.min(h, y + r + 1);
      for (int x = 0; x < w; x++) {
        final x0 = math.max(0, x - r), x1 = math.min(w, x + r + 1);
        final s = integ[y1 * (w + 1) + x1] -
            integ[y0 * (w + 1) + x1] -
            integ[y1 * (w + 1) + x0] +
            integ[y0 * (w + 1) + x0];
        final mean = s / ((y1 - y0) * (x1 - x0));
        if (gray[y * w + x] <= mean - 12) ink[y * w + x] = 1;
      }
    }
    return ink;
  }

  /// 五線の太さ t と線間隔 sp (線の中心どうし, px) を、縦方向の
  /// 黒の連なり / 黒に挟まれた白の連なりの長さの最頻値から求める。
  static (int, double) _staffMetrics(Uint8List ink, int w, int h) {
    final black = Int32List(12);
    final white = Int32List(60);
    for (int x = 0; x < w; x++) {
      int run = 0;
      int prev = 0;
      int whiteRun = -1; // 黒を見るまでは数えない (上端の白は挟まれていない)
      for (int y = 0; y <= h; y++) {
        final v = y < h ? ink[y * w + x] : 0;
        if (v != 0) {
          if (prev == 0) {
            if (whiteRun > 0 && whiteRun < 60) white[whiteRun]++;
            run = 0;
          }
          run++;
        } else {
          if (prev != 0) {
            if (run < 12) black[run]++;
            whiteRun = 0;
          }
          if (whiteRun >= 0) whiteRun++;
        }
        prev = v;
      }
    }
    int argmax(Int32List a, int from) {
      int best = -1, bi = from;
      for (int i = from; i < a.length; i++) {
        if (a[i] > best) {
          best = a[i];
          bi = i;
        }
      }
      return best > 0 ? bi : -1;
    }

    var t = argmax(black, 0);
    if (t < 1) t = t < 0 ? 2 : 1;
    var gap = argmax(white, t + 1);
    if (gap < 0) gap = 8;
    return (t, (gap + t).toDouble());
  }

  static double _interpMid(List<_Det> tr, double x) {
    if (x <= tr.first.x) return tr.first.ys[2];
    for (int i = 1; i < tr.length; i++) {
      if (x <= tr[i].x) {
        final a = tr[i - 1], b = tr[i];
        final f = (x - a.x) / (b.x - a.x);
        return a.ys[2] + f * (b.ys[2] - a.ys[2]);
      }
    }
    return tr.last.ys[2];
  }

  static int _reflect101(int i, int n) {
    if (n == 1) return 0;
    while (i < 0 || i >= n) {
      if (i < 0) i = -i;
      if (i >= n) i = 2 * n - 2 - i;
    }
    return i;
  }

  // ------------------------------------------------------------- 当てはめ

  /// 各線の観測 y = t_i + D(x, t_i) となる D を最小二乗で求める (正規化座標)。
  ///
  /// 各線のまっすぐな高さ t_i は未知なので、t_i と係数を交互に更新する。
  /// x を含まない項は t_i と区別できないので基底から外す (D(0, y) = 0)。
  /// 2 回目以降は残差の大きい点 (検出ミス) を外す。
  static StaffField? fitField(List<StaffLine> lines, int w, int h,
      {int iters = 4, int degY = StaffDewarp.degY}) {
    if (lines.length < minLines) return null; // 五線が少ないページは補正しない
    final nb = degX * (degY + 1);
    final xs = <Float64List>[
      for (final l in lines) Float64List.fromList(<double>[for (final v in l.xs) v / w]),
    ];
    final ys = <Float64List>[
      for (final l in lines) Float64List.fromList(<double>[for (final v in l.ys) v / h]),
    ];
    final t = Float64List.fromList(<double>[for (final y in ys) _median(y)]);
    final n = xs.fold<int>(0, (a, x) => a + x.length);
    final aMat = Float64List(n * nb);
    final b = Float64List(n);
    final wgt = Float64List(n)..fillRange(0, n, 1);
    Float64List? coef;
    final row = Float64List(nb);
    for (int it = 0; it < iters; it++) {
      int r = 0;
      for (int i = 0; i < xs.length; i++) {
        for (int j = 0; j < xs[i].length; j++) {
          _basis(xs[i][j], t[i], degY, row);
          aMat.setRange(r * nb, (r + 1) * nb, row);
          b[r] = ys[i][j] - t[i];
          r++;
        }
      }
      if (coef != null) {
        // 外れ点を落とす: 残差が残差の中央値の 6 倍 (かつ 3px) を超える点
        final res = Float64List(n);
        for (int r2 = 0; r2 < n; r2++) {
          double s = 0;
          for (int c = 0; c < nb; c++) {
            s += aMat[r2 * nb + c] * coef[c];
          }
          res[r2] = (s - b[r2]).abs();
        }
        final cut = math.max(6 * _median(res), 3.0 / h);
        for (int r2 = 0; r2 < n; r2++) {
          wgt[r2] = res[r2] < cut ? 1 : 0;
        }
      }
      coef = _weightedLstsq(aMat, b, wgt, n, nb);
      if (coef == null) return null;
      for (int i = 0; i < xs.length; i++) {
        final d = Float64List(xs[i].length);
        for (int j = 0; j < xs[i].length; j++) {
          _basis(xs[i][j], t[i], degY, row);
          double s = 0;
          for (int c = 0; c < nb; c++) {
            s += row[c] * coef[c];
          }
          d[j] = ys[i][j] - s;
        }
        t[i] = _median(d);
      }
    }
    double yLo = double.infinity, yHi = -double.infinity;
    for (final v in t) {
      yLo = math.min(yLo, v);
      yHi = math.max(yHi, v);
    }
    if (degY > 0 && yHi - yLo < 0.3) {
      // 線が縦の狭い範囲にしかない: y 方向の変化は推定できないので x だけの変位にする
      return fitField(lines, w, h, iters: iters, degY: 0);
    }
    double xLo = double.infinity, xHi = -double.infinity;
    for (final x in xs) {
      for (final v in x) {
        xLo = math.min(xLo, v);
        xHi = math.max(xHi, v);
      }
    }
    final field = StaffField(coef!, degY, xLo, xHi, yLo, yHi);
    // 安全策: 変位がページ高さの 12% を超える補正は誤検出とみなす
    for (int i = 0; i < 30; i++) {
      for (int j = 0; j < 30; j++) {
        final d = field.eval(xLo + (xHi - xLo) * i / 29, yLo + (yHi - yLo) * j / 29);
        if (d.abs() > 0.12) return null;
      }
    }
    return field;
  }

  static void _basis(double x, double y, int degY, Float64List out) {
    int i = 0;
    double xa = x;
    for (int a = 1; a <= degX; a++) {
      double yb = 1;
      for (int bb = 0; bb <= degY; bb++) {
        out[i++] = xa * yb;
        yb *= y;
      }
      xa *= x;
    }
  }

  /// 重み付き最小二乗 (正規方程式 + 部分ピボットのガウス消去)。
  static Float64List? _weightedLstsq(
      Float64List a, Float64List b, Float64List w, int n, int m) {
    final aug = Float64List(m * (m + 1));
    for (int r = 0; r < n; r++) {
      final wr = w[r];
      if (wr == 0) continue;
      final o = r * m;
      for (int i = 0; i < m; i++) {
        final ai = a[o + i] * wr;
        if (ai == 0) continue;
        for (int j = i; j < m; j++) {
          aug[i * (m + 1) + j] += ai * a[o + j];
        }
        aug[i * (m + 1) + m] += ai * b[r];
      }
    }
    for (int i = 0; i < m; i++) {
      for (int j = 0; j < i; j++) {
        aug[i * (m + 1) + j] = aug[j * (m + 1) + i];
      }
    }
    // ごく弱いリッジ (退化時の暴れ止め)
    double maxDiag = 0;
    for (int i = 0; i < m; i++) {
      maxDiag = math.max(maxDiag, aug[i * (m + 1) + i]);
    }
    if (maxDiag <= 0) return null;
    for (int i = 0; i < m; i++) {
      aug[i * (m + 1) + i] += maxDiag * 1e-12;
    }
    return _solve(aug, m);
  }

  /// 拡大係数行列 [m x (m+1)] を解く。
  static Float64List? _solve(Float64List aug, int m) {
    final c1 = m + 1;
    for (int col = 0; col < m; col++) {
      int piv = col;
      double best = aug[col * c1 + col].abs();
      for (int r = col + 1; r < m; r++) {
        final v = aug[r * c1 + col].abs();
        if (v > best) {
          best = v;
          piv = r;
        }
      }
      if (best < 1e-300) return null;
      if (piv != col) {
        for (int c = 0; c < c1; c++) {
          final tmp = aug[col * c1 + c];
          aug[col * c1 + c] = aug[piv * c1 + c];
          aug[piv * c1 + c] = tmp;
        }
      }
      final d = aug[col * c1 + col];
      for (int r = col + 1; r < m; r++) {
        final f = aug[r * c1 + col] / d;
        if (f == 0) continue;
        for (int c = col; c < c1; c++) {
          aug[r * c1 + c] -= f * aug[col * c1 + c];
        }
      }
    }
    final x = Float64List(m);
    for (int r = m - 1; r >= 0; r--) {
      double s = aug[r * c1 + m];
      for (int c = r + 1; c < m; c++) {
        s -= aug[r * c1 + c] * x[c];
      }
      x[r] = s / aug[r * c1 + r];
      if (!x[r].isFinite) return null;
    }
    return x;
  }

  // ------------------------------------------------------------------ 指標

  /// 各線の曲がり (3 次の当てはめ曲線の max - min, px) の中央値。線が無ければ NaN。
  static double bend(List<StaffLine> lines) {
    if (lines.isEmpty) return double.nan;
    final v = <double>[];
    for (final l in lines) {
      v.add(_polyRange(l.xs, l.ys, math.min(3, l.xs.length - 1)));
    }
    return _median(Float64List.fromList(v));
  }

  static double _polyRange(Float64List xs, Float64List ys, int deg) {
    double xMin = double.infinity, xMax = -double.infinity;
    for (final x in xs) {
      xMin = math.min(xMin, x);
      xMax = math.max(xMax, x);
    }
    final mid = (xMin + xMax) / 2;
    final half = math.max((xMax - xMin) / 2, 1e-9);
    final m = deg + 1;
    final aug = Float64List(m * (m + 1));
    final pw = Float64List(m);
    for (int i = 0; i < xs.length; i++) {
      final u = (xs[i] - mid) / half;
      pw[0] = 1;
      for (int k = 1; k < m; k++) {
        pw[k] = pw[k - 1] * u;
      }
      for (int r = 0; r < m; r++) {
        for (int c = 0; c < m; c++) {
          aug[r * (m + 1) + c] += pw[r] * pw[c];
        }
        aug[r * (m + 1) + m] += pw[r] * ys[i];
      }
    }
    final c = _solve(aug, m);
    if (c == null) return 0;
    double lo = double.infinity, hi = -double.infinity;
    for (int i = 0; i < 50; i++) {
      final u = -1 + 2 * i / 49;
      double v = 0, p = 1;
      for (int k = 0; k < m; k++) {
        v += c[k] * p;
        p *= u;
      }
      lo = math.min(lo, v);
      hi = math.max(hi, v);
    }
    return hi - lo;
  }

  static double _median(Float64List v) {
    if (v.isEmpty) return double.nan;
    final s = Float64List.fromList(v)..sort();
    final n = s.length;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
  }
}

class _Det {
  _Det(this.x, this.slope, this.ys);

  final double x;
  final double slope;

  /// 5 本の線の y (上から)。
  final Float64List ys;
}

/// 検出した 1 本の線の点列 (px)。xs は昇順。
class StaffLine {
  StaffLine(this.xs, this.ys);

  final Float64List xs;
  final Float64List ys;
}

/// 縦方向の変位場 D(x, y) = Σ c_ab x^a y^b (a = 1..degX, b = 0..degY)。
/// 座標は 0..1 の正規化。線のない端は最寄りの検出範囲の値を延長する
/// (高次多項式の外挿で暴れないように)。
class StaffField {
  StaffField(this.coef, this.degY, this.xLo, this.xHi, this.yLo, this.yHi);

  final Float64List coef;
  final int degY;
  final double xLo, xHi, yLo, yHi;

  double eval(double nx, double ny) {
    final x = nx.clamp(xLo, xHi);
    final y = ny.clamp(yLo, yHi);
    double s = 0, xa = x;
    int i = 0;
    for (int a = 1; a <= StaffDewarp.degX; a++) {
      double yb = 1;
      for (int b = 0; b <= degY; b++) {
        s += coef[i++] * xa * yb;
        yb *= y;
      }
      xa *= x;
    }
    return s;
  }
}

/// 推定した補正 (変位場の合成)。補正後の正規化座標 → 補正前の正規化 y を返す。
///
/// 反復で求めた場は「後の回ほど出力側」なので、出力側から順に適用する:
/// y2 = y + D_last(x, y) → y1 = y2 + D_prev(x, y2) → ...
/// 画素ごとに多項式を評価すると重いので、格子で前計算して双一次補間する。
class PageDewarp {
  PageDewarp(this.fields) {
    for (int j = 0; j <= _gh; j++) {
      for (int i = 0; i <= _gw; i++) {
        _disp[j * (_gw + 1) + i] = exactSourceY(i / _gw, j / _gh) - j / _gh;
      }
    }
  }

  final List<StaffField> fields;

  static const int _gw = 64;
  static const int _gh = 96;

  /// 格子点での変位 (補正前 y - 補正後 y, 正規化)。
  final Float64List _disp = Float64List((_gw + 1) * (_gh + 1));

  double exactSourceY(double nx, double ny) {
    var y = ny;
    for (int i = fields.length - 1; i >= 0; i--) {
      y += fields[i].eval(nx, y);
    }
    return y;
  }

  /// 格子補間版 (保存時の全画素の再サンプリング用)。格子の外 (0..1 の外) は
  /// 端の変位をそのまま延長する。画素ループで呼ぶので num を返す clamp は使わない。
  double sourceY(double nx, double ny) {
    final gx = nx <= 0 ? 0.0 : (nx >= 1 ? _gw.toDouble() : nx * _gw);
    final gy = ny <= 0 ? 0.0 : (ny >= 1 ? _gh.toDouble() : ny * _gh);
    var i0 = gx.toInt();
    if (i0 > _gw - 1) i0 = _gw - 1;
    var j0 = gy.toInt();
    if (j0 > _gh - 1) j0 = _gh - 1;
    final fx = gx - i0, fy = gy - j0;
    final o = j0 * (_gw + 1) + i0;
    final top = _disp[o] + (_disp[o + 1] - _disp[o]) * fx;
    final bot = _disp[o + _gw + 1] + (_disp[o + _gw + 2] - _disp[o + _gw + 1]) * fx;
    return ny + top + (bot - top) * fy;
  }

  /// グレースケール画像に補正をかける (検出のやり直し・評価用)。
  /// 格子補間版の写像を使う (画素ごとに多項式を評価すると実機で数百 ms かかる)。
  Uint8List remapGray(Uint8List gray, int w, int h) {
    final out = Uint8List(w * h);
    final hMax = h - 1.0;
    for (int y = 0; y < h; y++) {
      final ny = y / h;
      final row = y * w;
      for (int x = 0; x < w; x++) {
        var sy = sourceY(x / w, ny) * h;
        if (sy < 0) sy = 0;
        if (sy > hMax) sy = hMax;
        final y0 = sy.toInt();
        final y1 = y0 + 1 < h ? y0 + 1 : y0;
        final f = sy - y0;
        out[row + x] = (gray[y0 * w + x] * (1 - f) + gray[y1 * w + x] * f + 0.5).toInt();
      }
    }
    return out;
  }
}
