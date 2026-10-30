// 紙面検出モデル (assets/models/paper_seg.onnx) の実写評価ハーネス。
//
// アプリの切り抜き画面と同じ経路 (正立画像 → 長辺 1000px → 輝度 →
// OrtSessionBundle.detectPaperQuad) で推論し、正解四隅と比べる。
//
// データ: `<id>.jpg` + `<id>.json` (QuadLabel 形式) を置いたフォルダ。
//   アプリの「検出改善用に切り抜き結果を保存」で貯めたものを
//   adb pull してそのまま使える。
//
// 実行 (Windows):
//   pwsh tools/setup_ort_windows.ps1           # 初回のみ ORT を取得
//   flutter test test/paper_net_eval_test.dart
//
// 環境変数 (省略時は既定値):
//   PAPER_EVAL_DIR  評価データ     (training_data/eval)
//   PAPER_MODEL     ONNX モデル    (assets/models/paper_seg.onnx)
//   ORT_DYLIB       ORT 共有ライブラリ (tools/ort/onnxruntime.dll)
//   PAPER_EVAL_OUT  レポート出力先  (build/paper_eval)
//   PAPER_DUMP_MASK 1 なら穴埋め後のマスク (256x256) も <id>_mask.png に書く
//
// データかライブラリが無い環境ではスキップする。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:futoji/services/detector.dart';
import 'package:futoji/services/fast_decode.dart';
import 'package:futoji/services/ort_ffi.dart';
import 'package:futoji/services/quad_label.dart';


/// 成功判定に使う平均角誤差のしきい値 (画像対角線比)。
const List<double> successThresholds = <double>[0.01, 0.02, 0.05];

String _env(String key, String fallback) =>
    Platform.environment[key]?.trim().isNotEmpty == true
        ? Platform.environment[key]!.trim()
        : fallback;

class _Result {
  _Result(this.id, this.label, this.pred);

  final String id;
  final QuadLabel label;
  final List<Offset>? pred;
  double meanErr = double.infinity;
  double maxErr = double.infinity;
  double iou = 0;
  double? captureMeanErr; // 保存時点のモデル予測の誤差

  bool get detected => pred != null;
}

void main() {
  // アプリと同じ端末デコーダ (dart:ui の ImageDescriptor) を使うため
  TestWidgetsFlutterBinding.ensureInitialized();
  final evalDir = Directory(_env('PAPER_EVAL_DIR', 'training_data/eval'));
  final modelFile = File(_env('PAPER_MODEL', 'assets/models/paper_seg.onnx'));
  final ortPath = _env('ORT_DYLIB', 'tools/ort/onnxruntime.dll');
  final outDir = Directory(_env('PAPER_EVAL_OUT', 'build/paper_eval'));
  // 四隅の外側パディング (短辺比)。既定はアプリと同じ値。
  final pad = double.parse(
      _env('PAPER_PAD', DocumentDetector.netCornerPad.toString()));
  // 実験用: 1 なら snapQuadToEdges を後段にかけて評価する
  final snap = _env('PAPER_SNAP', '0') == '1';
  final simStream = _env('PAPER_SIM_STREAM', '0') == '1';
  final openRadius = int.parse(_env(
      'PAPER_OPEN', DocumentDetector.netMaskOpenRadius.toString()));
  // 実験用: 0 なら辺の直線当てはめ (角の補正) を無効にして評価する
  final refineEdges = _env('PAPER_REFINE', '1') == '1';
  // マスクと四角形の IoU の下限 (既定はアプリと同じ値)
  final minAgree = double.parse(
      _env('PAPER_MIN_AGREE', DocumentDetector.netMinMaskQuadIoU.toString()));
  final dumpMask = _env('PAPER_DUMP_MASK', '0') == '1';

  final labelFiles = evalDir.existsSync()
      ? (evalDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  String? skipReason;
  if (labelFiles.isEmpty) {
    skipReason = '評価データがありません: ${evalDir.path}';
  } else if (!File(ortPath).existsSync()) {
    skipReason = 'ORT ライブラリがありません: $ortPath '
        '(tools/setup_ort_windows.ps1 で取得)';
  } else if (!modelFile.existsSync()) {
    skipReason = 'モデルがありません: ${modelFile.path}';
  }

  test('paper net eval on labeled captures',
      skip: skipReason ?? false,
      timeout: const Timeout(Duration(minutes: 20)), () async {
    final bundle = OrtApiBindings.createPaperSessionBundle(
      modelFile.readAsBytesSync(),
      libraryPath: File(ortPath).absolute.path,
    );
    outDir.createSync(recursive: true);

    final results = <_Result>[];
    for (final lf in labelFiles) {
      final id = lf.uri.pathSegments.last.replaceAll('.json', '');
      final label = QuadLabel.fromJson(
          (jsonDecode(lf.readAsStringSync()) as Map).cast<String, Object?>());
      final imageFile = File('${evalDir.path}/${label.image}');
      if (!imageFile.existsSync()) {
        // ignore: avoid_print
        print('skip $id: 画像がありません (${label.image})');
        continue;
      }
      // 切り抜き画面と同じデコード (fast_decode.dart)。image パッケージで縮小すると
      // 縮小方式の違いで折れのある画像などの結果が実機とずれていた
      final work = await decodeWorkImage(imageFile.readAsBytesSync());
      // PAPER_SIM_STREAM=1: ライブ検出の入力を再現する (長辺 1920 のフレームを
      // extractFramePixels と同じく 4 画素おきに間引く → 長辺 480)。
      // モデルが灰色なら detectPaperQuad が輝度にして渡す
      final (rgb, gw, gh) = simStream
          ? _streamRgb(imageFile.readAsBytesSync())
          : (work.getBytes(order: img.ChannelOrder.rgb), work.width, work.height);
      double? agreement;
      final flat = bundle.detectPaperQuad(rgb, gw, gh,
          channels: 3,
          pad: pad,
          openRadius: openRadius,
          refineEdges: refineEdges,
          minMaskQuadIoU: minAgree,
          onAgreement: (v) => agreement = v,
          onDebug: dumpMask
              ? (input, mask, filled, fill) {
                  final m = img.Image(width: 256, height: 256, numChannels: 1);
                  for (int i = 0; i < filled.length; i++) {
                    m.setPixelR(i % 256, i ~/ 256, filled[i]);
                  }
                  File('${outDir.path}/${id}_mask.png')
                      .writeAsBytesSync(img.encodePng(m));
                }
              : null);
      // ignore: avoid_print
      print('agreement $id ${agreement?.toStringAsFixed(3) ?? '-'} '
          '${label.corners == null ? 'negative' : 'positive'}');
      var pred = flat == null
          ? null
          : <Offset>[
              for (int i = 0; i < 8; i += 2) Offset(flat[i], flat[i + 1]),
            ];
      if (pred != null && snap) {
        // 実験用: 四隅を写真のエッジへ吸着させる後処理
        pred = DocumentDetector.snapQuadToEdges(
            pred, DocumentDetector.lumaOf(rgb, 3), gw, gh);
      }

      final r = _Result(id, label, pred);
      final truth = label.corners;
      if (pred != null && truth != null) {
        // 紙が画面からはみ出した難例は、正解の角が写真の外にある (辺を延長した位置)。アプリの
        // 枠は写真の外へ出せないので、写真の端に寄せた角と比べる (IoU は元から写真の中だけ)
        final inFrame = <Offset>[
          for (final c in truth)
            Offset(c.dx.clamp(0.0, 1.0), c.dy.clamp(0.0, 1.0)),
        ];
        final e = QuadMetrics.cornerError(pred, inFrame, work.width, work.height);
        r.meanErr = e.mean;
        r.maxErr = e.max;
        r.iou = QuadMetrics.quadIoU(pred, truth, work.width, work.height);
      }
      if (label.predicted != null && truth != null) {
        r.captureMeanErr = QuadMetrics.cornerError(
                label.predicted!, truth, label.width, label.height)
            .mean;
      }
      results.add(r);
      _writeOverlay(work, truth, pred, File('${outDir.path}/$id.jpg'));
    }

    final report = _report(results, modelFile);
    File('${outDir.path}/report.md').writeAsStringSync(report);
    File('${outDir.path}/summary.json').writeAsStringSync(
        // NaN / Infinity (空グループ・未検出) は null として書く
        JsonEncoder.withIndent('  ', (_) => null)
            .convert(_summary(results, modelFile)));
    // ignore: avoid_print
    print(report);
    // ignore: avoid_print
    print('overlays / report: ${outDir.absolute.path}');
    expect(results, isNotEmpty);
  });
}

/// ライブ検出の入力の再現: 長辺 1920 のカメラフレーム → 4 画素おきに間引いた RGB。
(Uint8List, int, int) _streamRgb(Uint8List bytes) {
  var im = img.decodeImage(bytes)!;
  const frameLong = 1920;
  im = im.width >= im.height
      ? img.copyResize(im, width: frameLong, interpolation: img.Interpolation.average)
      : img.copyResize(im, height: frameLong, interpolation: img.Interpolation.average);
  final full = im.getBytes(order: img.ChannelOrder.rgb);
  const d = 4; // camera_screen: image.width >= 1280 なら 4
  final dw = im.width ~/ d, dh = im.height ~/ d;
  final out = Uint8List(dw * dh * 3);
  for (int y = 0; y < dh; y++) {
    for (int x = 0; x < dw; x++) {
      final i = (y * d * im.width + x * d) * 3;
      final o = (y * dw + x) * 3;
      out[o] = full[i];
      out[o + 1] = full[i + 1];
      out[o + 2] = full[i + 2];
    }
  }
  return (out, dw, dh);
}

/// 正解 (緑) と予測 (赤) を重ねた確認用画像。
void _writeOverlay(
    img.Image work, List<Offset>? truth, List<Offset>? pred, File out) {
  final canvas = img.Image.from(work);
  void drawQuad(List<Offset> q, img.Color color) {
    for (int i = 0; i < 4; i++) {
      final a = q[i];
      final b = q[(i + 1) % 4];
      img.drawLine(canvas,
          x1: (a.dx * work.width).round(),
          y1: (a.dy * work.height).round(),
          x2: (b.dx * work.width).round(),
          y2: (b.dy * work.height).round(),
          color: color,
          thickness: 3);
    }
  }

  if (truth != null) drawQuad(truth, img.ColorRgb8(40, 220, 60));
  if (pred != null) drawQuad(pred, img.ColorRgb8(240, 40, 40));
  out.writeAsBytesSync(img.encodeJpg(canvas, quality: 80));
}

double _median(List<double> xs) {
  if (xs.isEmpty) return double.nan;
  final s = List<double>.of(xs)..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

String _pct(double v) => v.isFinite ? '${(v * 100).toStringAsFixed(2)}%' : '-';

Map<String, Object?> _groupStats(List<_Result> rs) {
  final det = rs.where((r) => r.detected).toList();
  final errs = det.map((r) => r.meanErr).toList();
  return <String, Object?>{
    'n': rs.length,
    'detection_rate': rs.isEmpty ? 0.0 : det.length / rs.length,
    'median_corner_err': _median(errs),
    'mean_corner_err':
        errs.isEmpty ? double.nan : errs.reduce((a, b) => a + b) / errs.length,
    'mean_iou': rs.isEmpty
        ? 0.0
        : rs.map((r) => r.iou).reduce((a, b) => a + b) / rs.length,
    for (final t in successThresholds)
      'success@${(t * 100).round()}%': rs.isEmpty
          ? 0.0
          : rs.where((r) => r.meanErr <= t).length / rs.length,
  };
}

/// 紙なしラベル (corners=null) に対して紙を検出してしまった割合。
double _falsePositiveRate(List<_Result> negatives) => negatives.isEmpty
    ? double.nan
    : negatives.where((r) => r.detected).length / negatives.length;

Map<String, Object?> _summary(List<_Result> all, File model) {
  final rs = all.where((r) => !r.label.isNegative).toList();
  final neg = all.where((r) => r.label.isNegative).toList();
  final capture = rs.where((r) => r.captureMeanErr != null).toList();
  return <String, Object?>{
    'evaluated_at': DateTime.now().toIso8601String(),
    'model': model.path,
    'model_bytes': model.lengthSync(),
    'all': _groupStats(rs),
    'edited': _groupStats(rs.where((r) => r.label.edited).toList()),
    'unedited': _groupStats(rs.where((r) => !r.label.edited).toList()),
    'negatives': <String, Object?>{
      'n': neg.length,
      'false_positive_rate': _falsePositiveRate(neg),
    },
    'capture_time_median_corner_err':
        _median(capture.map((r) => r.captureMeanErr!).toList()),
  };
}

String _report(List<_Result> all, File model) {
  final rs = all.where((r) => !r.label.isNegative).toList();
  final neg = all.where((r) => r.label.isNegative).toList();
  final b = StringBuffer()
    ..writeln('# Paper net eval')
    ..writeln()
    ..writeln('- model: `${model.path}` (${model.lengthSync()} bytes)')
    ..writeln('- corner pad: ${Platform.environment['PAPER_PAD'] ?? DocumentDetector.netCornerPad}'
        ' / edge snap: ${Platform.environment['PAPER_SNAP'] == '1' ? 'on' : 'off'}'
        ' / open: ${Platform.environment['PAPER_OPEN'] ?? DocumentDetector.netMaskOpenRadius}'
        ' / input: ${Platform.environment['PAPER_SIM_STREAM'] == '1' ? 'live stream (480px)' : 'crop (1000px)'}')
    ..writeln('- samples: 紙あり ${rs.length} / 紙なし ${neg.length}')
    ..writeln('- 紙なし画像での誤検出率: ${_pct(_falsePositiveRate(neg))} '
        '(${neg.where((r) => r.detected).length}/${neg.length})')
    ..writeln('- 角誤差 = 対応する角の距離 / 画像対角線 (4 角平均)。'
        '写真の外にある正解の角は写真の端に寄せて比べる。'
        '未検出は成功率・IoU で失敗 (0) 扱い')
    ..writeln()
    ..writeln('| group | n | 検出率 | 角誤差 中央値 | 平均 IoU | '
        '${successThresholds.map((t) => '成功@${(t * 100).round()}%').join(' | ')} |')
    ..writeln('|---|---|---|---|---|${successThresholds.map((_) => '---').join('|')}|');
  void row(String name, List<_Result> g) {
    final s = _groupStats(g);
    b.writeln('| $name | ${s['n']} | ${_pct(s['detection_rate']! as double)} | '
        '${_pct(s['median_corner_err']! as double)} | '
        '${(s['mean_iou']! as double).toStringAsFixed(3)} | '
        '${successThresholds.map((t) => _pct(s['success@${(t * 100).round()}%']! as double)).join(' | ')} |');
  }

  row('all', rs);
  row('手修正あり', rs.where((r) => r.label.edited).toList());
  row('手修正なし', rs.where((r) => !r.label.edited).toList());

  b
    ..writeln()
    ..writeln('## ワースト (角誤差の大きい順)')
    ..writeln()
    ..writeln('| id | 検出 | 平均誤差 | 最大誤差 | IoU | 保存時の誤差 | 手修正 |')
    ..writeln('|---|---|---|---|---|---|---|');
  final worst = List<_Result>.of(rs)
    ..sort((a, b) => b.meanErr.compareTo(a.meanErr));
  for (final r in worst.take(math.min(30, worst.length))) {
    b.writeln('| ${r.id} | ${r.detected ? '○' : '×'} | ${_pct(r.meanErr)} | '
        '${_pct(r.maxErr)} | ${r.iou.toStringAsFixed(3)} | '
        '${r.captureMeanErr == null ? '-' : _pct(r.captureMeanErr!)} | '
        '${r.label.edited ? '○' : ''} |');
  }
  if (neg.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## 紙なし画像')
      ..writeln()
      ..writeln('| id | 判定 |')
      ..writeln('|---|---|');
    for (final r in neg) {
      b.writeln('| ${r.id} | ${r.detected ? '誤検出' : '紙なし (正解)'} |');
    }
  }
  return b.toString();
}
