import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/music_page.dart';
import '../models/stroke.dart';

/// PDF に載せる 1 ページ分の入力。
class PdfPageSource {
  const PdfPageSource({
    required this.imageBytes,
    required this.widthPx,
    required this.heightPx,
    required this.strokes,
  });

  /// 本文画像。PDF に直接埋め込める形式 (JPEG を推奨 / PNG も可) のバイト列。
  final Uint8List imageBytes;
  final int widthPx;
  final int heightPx;

  /// 手書きメモ (正規化座標)
  final List<Stroke> strokes;
}

class PdfExportResult {
  const PdfExportResult({required this.file, required this.pageCount});

  final File file;
  final int pageCount;
}

/// 純 Dart 部分: ページ画像 + 手書きストロークを合成した PDF を組み立てる。
/// (ホストの単体テストからも実行できる。compress=false はテスト検査用)
Future<Uint8List> buildPdfBytes(List<PdfPageSource> pages,
    {double sourceDpi = 150, bool compress = true}) async {
  final doc = pw.Document(compress: compress);
  final scale = 72.0 / sourceDpi; // px -> pt
  for (final p in pages) {
    final w = p.widthPx * scale;
    final h = p.heightPx * scale;
    final image = pw.MemoryImage(p.imageBytes);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(w, h),
        margin: const pw.EdgeInsets.all(0),
        build: (context) => pw.Stack(
          children: <pw.Widget>[
            pw.Positioned.fill(
              child: pw.Image(image, fit: pw.BoxFit.fill),
            ),
            if (p.strokes.isNotEmpty)
              pw.Positioned.fill(
                child: pw.CustomPaint(
                  painter: (PdfGraphics g, PdfPoint size) =>
                      _drawStrokes(g, size, p.strokes),
                ),
              ),
          ],
        ),
      ),
    );
  }
  return doc.save();
}

/// PdfGraphics は原点が左下のため、ストロークの y は上下反転して描く。
void _drawStrokes(PdfGraphics g, PdfPoint size, List<Stroke> strokes) {
  void pathOf(Stroke s) {
    g.moveTo(s.points.first.dx * size.x, size.y - s.points.first.dy * size.y);
    for (int i = 1; i < s.points.length; i++) {
      final p = s.points[i];
      g.lineTo(p.dx * size.x, size.y - p.dy * size.y);
    }
  }

  for (final s in strokes) {
    if (s.points.isEmpty) continue;
    final widthPt = (s.width * size.x).clamp(0.2, 60.0);
    g.setLineCap(PdfLineCap.round);
    if (s.points.length == 1) {
      final p0 = s.points.first;
      final x = p0.dx * size.x;
      final y = size.y - p0.dy * size.y;
      // 白縁 → 本色 (画面表示と同じ見え方にする)
      g.setFillColor(const PdfColor(1, 1, 1));
      g.drawEllipse(x, y, widthPt / 2 + 1.2, widthPt / 2 + 1.2);
      g.fillPath();
      g.setFillColor(PdfColor.fromInt(s.color));
      g.drawEllipse(x, y, widthPt / 2, widthPt / 2);
      g.fillPath();
      continue;
    }
    // 白縁 (暗い紙面の上でも黒ペンを見やすく)
    g.setStrokeColor(const PdfColor(1, 1, 1));
    g.setLineWidth(widthPt + 2.4);
    pathOf(s);
    g.strokePath();
    g.setStrokeColor(PdfColor.fromInt(s.color));
    g.setLineWidth(widthPt);
    pathOf(s);
    g.strokePath();
  }
}

/// ファイル名に使えない文字を置換する。
String safeFileName(String name) =>
    name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

/// デバイス向けラッパ: 保存済み WebP を PDF 埋め込み用 PNG に変換し、
/// 手書きメモを合成した PDF を一時フォルダに書き出す。
Future<PdfExportResult> exportDocumentPdf({
  required String title,
  required List<MusicPage> pages,
  void Function(int done, int total)? onProgress,
}) async {
  final sources = <PdfPageSource>[];
  for (int i = 0; i < pages.length; i++) {
    final p = pages[i];
    final webp = await File(p.imagePath).readAsBytes();
    // pdf パッケージは JPEG を DCTDecode パススルーで埋め込めるため
    // WebP -> JPEG に変換する (PNG より PDF サイズが小さくて済む)
    final jpeg = await FlutterImageCompress.compressWithList(
      webp,
      format: CompressFormat.jpeg,
      quality: 90,
    );
    sources.add(PdfPageSource(
      imageBytes: jpeg,
      widthPx: p.width,
      heightPx: p.height,
      strokes: p.strokes,
    ));
    onProgress?.call(i + 1, pages.length);
  }

  final bytes = await buildPdfBytes(sources);
  final dir = await getTemporaryDirectory();
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final file = File(
      '${dir.path}${Platform.pathSeparator}${safeFileName(title)}_$stamp.pdf');
  await file.writeAsBytes(bytes, flush: true);
  return PdfExportResult(file: file, pageCount: pages.length);
}
