import 'dart:isolate';
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

  /// 傾き探索で列をまとめる幅 (px)。
  static const int _blockW = 5;

  /// 検出の短冊の走査を何本の isolate で分けるか。既定は 1 (分けない)。
  ///
  /// 実機 (Cortex-A76 x2 + A55 x6) では分けるほど遅かった (1 本 約 0.75 秒 →
  /// 2 本 約 1.1 秒 → 4 本 約 1.4 秒)。isolate の起動は 1 本 0.5ms と安いが、
  /// 二値化済みの画像 (約 2MB) を 1 本ごとにコピーするのに約 20ms かかり、
  /// 検出 3 回 x 本数ぶん積み上がる。省電力コアに回った分の待ちも出る。
  /// `--dart-define=DEWARP_WORKERS=n` で上書きできる (計測用)。
  static int get defaultWorkers {
    const forced = int.fromEnvironment('DEWARP_WORKERS');
    return forced > 0 ? forced : 1;
  }

  /// 推定する。[gray] は台形補正済みのグレースケール (幅 [workWidth] 前後)。
  ///
  /// 検出 → 当てはめを 2 回繰り返す (急な曲がりは 1 回では拾い切れないため)。
  /// 各回とも、補正後に検出し直して曲がりが 2 割以上減らなければ、その回は捨てる。
  /// 検出の大半を占める短冊の走査は [workers] 本の isolate で分担する
  /// (1 なら呼び出し元の isolate だけで処理する)。
  static Future<PageDewarp?> estimate(Uint8List gray, int w, int h,
      {int passes = 2, int workers = 1}) async {
    final fields = <StaffField>[];
    var cur = gray;
    var lines = await detectLinesParallel(cur, w, h, workers);
    for (int pass = 0; pass < passes; pass++) {
      final field = fitField(lines, w, h);
      if (field == null) break;
      final next = PageDewarp(<StaffField>[...fields, field]);
      final nxt = next.remapGray(gray, w, h);
      final nextLines = await detectLinesParallel(nxt, w, h, workers);
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
    final pr = _prepare(gray, w, h);
    return _assemble(pr, <List<_Det>>[_scanStrips(pr, 0, 1)]);
  }

  /// [detectLines] の並列版。短冊を [workers] 組に交互に振り分け、
  /// 1 組は呼び出し元で、残りは別 isolate で走査する。
  static Future<List<StaffLine>> detectLinesParallel(
      Uint8List gray, int w, int h, int workers) async {
    final pr = _prepare(gray, w, h);
    final n = math.min(workers, pr.nStrips);
    if (n <= 1) return _assemble(pr, <List<_Det>>[_scanStrips(pr, 0, 1)]);
    final others = <Future<List<_Det>>>[
      for (int i = 1; i < n; i++) Isolate.run(() => _scanStrips(pr, i, n)),
    ];
    final mine = _scanStrips(pr, 0, n);
    return _assemble(pr, <List<_Det>>[mine, ...await Future.wait(others)]);
  }

  /// 二値化・線の太さと間隔の推定・転置 (短冊の走査の前処理)。
  static _Prep _prepare(Uint8List gray, int w, int h) {
    final inkT = _adaptiveInkT(gray, w, h);
    final (t, sp) = _staffMetrics(inkT, w, h);
    return _Prep(inkT, w, h, t, sp);
  }

  /// 短冊 [first], first + [stride], ... を走査し、見つかった五線の候補を返す
  /// (別 isolate で動かすので、引数は送れるデータだけにしてある)。
  static List<_Det> _scanStrips(_Prep pr, int first, int stride) {
    final inkT = pr.inkT;
    final h = pr.h, t = pr.t, sp = pr.sp;
    final sw = pr.sw, step = pr.step;
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
    final nBlocks = (sw + _blockW - 1) ~/ _blockW;
    final blockSum = Int32List(nBlocks * h);
    final blockCenter = Float64List(nBlocks);
    for (int si0 = first; si0 < pr.nStrips; si0 += stride) {
      final x0 = si0 * step;
      // 1. 傾きを振った投影のうち、最も鋭い (二乗和が最大の) もの。
      //    -0.2..0.2 を 0.025 刻み (17 通り) の格子で、粗密に探す
      //    (0.1 刻みの 5 通り → ±0.05 → ±0.025。全通りの約半分の計算で済む)。
      //    短冊を 5 列ずつのまとまりに分けて先に足しておき、傾きごとには
      //    まとまりの中心でのずれでまとまりを足し合わせる (まとまり内のずれの差は
      //    最大 0.4px で、後段の ±1px の許容に収まる。傾きごとの計算が 1/5 になる)。
      final xc = (sw - 1) / 2;
      for (int bi = 0; bi < nBlocks; bi++) {
        final xa = bi * _blockW, xb = math.min(sw, xa + _blockW);
        final o = bi * h;
        blockSum.fillRange(o, o + h, 0);
        for (int x = xa; x < xb; x++) {
          final base = (x0 + x) * h;
          for (int y = 0; y < h; y++) {
            blockSum[o + y] += inkT[base + y];
          }
        }
        blockCenter[bi] = (xa + xb - 1) / 2 - xc;
      }
      final scores = Float64List(nSlopes)..fillRange(0, nSlopes, -1);
      double bestScore = -1;
      int bestSi = nSlopes ~/ 2;
      void tryslope(int si) {
        if (si < 0 || si >= nSlopes || scores[si] >= 0) return;
        final s = -0.2 + 0.4 * si / (nSlopes - 1);
        p.fillRange(0, h, 0);
        for (int bi = 0; bi < nBlocks; bi++) {
          final sh = (s * blockCenter[bi]).round() % h;
          final o = bi * h;
          // p[y] += block[(y + sh) mod h]
          final split = h - sh;
          for (int y = 0; y < split; y++) {
            p[y] += blockSum[o + y + sh];
          }
          for (int y = split; y < h; y++) {
            p[y] += blockSum[o + y + sh - h];
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
    return dets;
  }

  /// 短冊ごとの候補をつないで五線にする。[parts] は [_scanStrips] の結果の組。
  static List<StaffLine> _assemble(_Prep pr, List<List<_Det>> parts) {
    final w = pr.w, sp = pr.sp, sw = pr.sw, step = pr.step;
    // x の昇順 (同じ短冊の中は見つけた順) に並べ直す。組ごとに x は昇順なので安定に併合する
    final dets = <_Det>[for (final p in parts) ...p];
    final order = List<int>.generate(dets.length, (i) => i)
      ..sort((a, b) {
        final c = dets[a].x.compareTo(dets[b].x);
        return c != 0 ? c : a.compareTo(b);
      });
    final sorted = <_Det>[for (final i in order) dets[i]];

    // 3. 短冊をまたいでつなぐ
    final tracks = <List<_Det>>[];
    for (final d in sorted) {
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
  ///
  /// 結果は列ごとに連続した並び (inkT[x * h + y]) で返す (後段の投影と
  /// 連なりの集計が列方向に走るため)。積分画像は作らず、縦の窓の和を列ごとに
  /// 持って行ごとに更新し、横は行内の累積和で取る (確保するのは列数ぶんだけ。
  /// 積分画像は 1 回の検出で約 16MB になり、実機で GC が効いていた)。
  static Uint8List _adaptiveInkT(Uint8List gray, int w, int h) {
    const r = 15;
    final col = Int32List(w); // 行 [y0, y1) の列ごとの和
    final pre = Int32List(w + 1); // col の累積和
    final inkT = Uint8List(w * h);
    int y0 = 0, y1 = 0;
    for (int y = 0; y < h; y++) {
      final ny0 = y - r < 0 ? 0 : y - r;
      final ny1 = y + r + 1 > h ? h : y + r + 1;
      while (y1 < ny1) {
        final o = y1 * w;
        for (int x = 0; x < w; x++) {
          col[x] += gray[o + x];
        }
        y1++;
      }
      while (y0 < ny0) {
        final o = y0 * w;
        for (int x = 0; x < w; x++) {
          col[x] -= gray[o + x];
        }
        y0++;
      }
      for (int x = 0; x < w; x++) {
        pre[x + 1] = pre[x] + col[x];
      }
      final rows = y1 - y0;
      final o = y * w;
      for (int x = 0; x < w; x++) {
        final x0 = x - r < 0 ? 0 : x - r;
        final x1 = x + r + 1 > w ? w : x + r + 1;
        final cnt = rows * (x1 - x0);
        // gray <= 平均 - 12  ⇔  gray * cnt <= 和 - 12 * cnt (割り算を避ける)
        if (gray[o + x] * cnt <= pre[x1] - pre[x0] - 12 * cnt) inkT[x * h + y] = 1;
      }
    }
    return inkT;
  }

  /// 五線の太さ t と線間隔 sp (線の中心どうし, px) を、縦方向の
  /// 黒の連なり / 黒に挟まれた白の連なりの長さの最頻値から求める。
  static (int, double) _staffMetrics(Uint8List inkT, int w, int h) {
    final black = Int32List(12);
    final white = Int32List(60);
    for (int x = 0; x < w; x++) {
      int run = 0;
      int prev = 0;
      int whiteRun = -1; // 黒を見るまでは数えない (上端の白は挟まれていない)
      final base = x * h;
      for (int y = 0; y <= h; y++) {
        final v = y < h ? inkT[base + y] : 0;
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

class _Prep {
  _Prep(this.inkT, this.w, this.h, this.t, this.sp)
      : sw = math.max(40, w ~/ 24),
        step = math.max(40, w ~/ 24) ~/ 2;

  /// インク (0/1) を列ごとに並べたもの: inkT[x * h + y]。
  final Uint8List inkT;
  final int w, h;

  /// 五線の太さ、線間隔 (px)。
  final int t;
  final double sp;

  /// 短冊の幅と送り (半分ずつ重ねる)。
  final int sw, step;

  int get nStrips => w < sw ? 0 : (w - sw) ~/ step + 1;
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
