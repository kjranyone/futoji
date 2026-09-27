import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:mymusicbook/models/stroke.dart';
import 'package:mymusicbook/services/pdf_export.dart';

void main() {
  Uint8List tinyPng(int w, int h, [int value = 128]) {
    final im = img.Image(width: w, height: h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        im.setPixelRgb(x, y, value, value, value);
      }
    }
    return Uint8List.fromList(img.encodePng(im));
  }

  test('画像のみの PDF が生成できる', () async {
    final bytes = await buildPdfBytes(<PdfPageSource>[
      PdfPageSource(
        imageBytes: tinyPng(32, 48),
        widthPx: 32,
        heightPx: 48,
        strokes: const <Stroke>[],
      ),
    ]);
    final header = String.fromCharCodes(bytes.sublist(0, 5));
    final trailer = String.fromCharCodes(bytes.sublist(bytes.length - 6));
    expect(header, '%PDF-');
    expect(trailer.trim(), contains('%%EOF'));
  });

  test('手書きストロークを合成した PDF が生成できる', () async {
    final plain = await buildPdfBytes(<PdfPageSource>[
      PdfPageSource(
        imageBytes: tinyPng(32, 48),
        widthPx: 32,
        heightPx: 48,
        strokes: const <Stroke>[],
      ),
    ], compress: false);
    final annotated = await buildPdfBytes(<PdfPageSource>[
      PdfPageSource(
        imageBytes: tinyPng(32, 48),
        widthPx: 32,
        heightPx: 48,
        strokes: <Stroke>[
          Stroke(
            color: 0xFFE53935,
            width: 0.05,
            points: const <Offset>[Offset(0.1, 0.1), Offset(0.5, 0.4), Offset(0.8, 0.2)],
          ),
          Stroke(
            color: 0xFF212121,
            width: 0.03,
            points: const <Offset>[Offset(0.3, 0.3)],
          ),
        ],
      ),
    ], compress: false);
    expect(annotated.length, greaterThan(plain.length));
    final text = String.fromCharCodes(annotated);
    // ストローク色設定オペレータ (RG = 線色 / rg = 塗り色) が入っている
    expect(text.contains(' RG') || text.contains(' rg'), isTrue,
        reason: 'ストローク色が PDF コンテンツに反映されていない');
  });

  test('複数ページの PDF でページ数が保存される', () async {
    final bytes = await buildPdfBytes(<PdfPageSource>[
      for (int i = 0; i < 3; i++)
        PdfPageSource(
          imageBytes: tinyPng(16, 16, 60 + i * 40),
          widthPx: 16,
          heightPx: 16,
          strokes: const <Stroke>[],
        ),
    ], compress: false);
    final text = String.fromCharCodes(bytes);
    // /Type/Page (Pages にマッチしないよう後続文字を除外)
    expect(RegExp('/Type/Page(?![a-zA-Z])').allMatches(text).length, 3);
  });

  test('safeFileName はファイル名に使えない文字を置換する', () {
    expect(safeFileName('バイオリン/基礎: Vol.1'), 'バイオリン_基礎_ Vol.1');
    expect(safeFileName('  query  '), 'query');
  });

  test('生成した PDF は実際のファイルとして有効なヘッダを持つ', () async {
    final bytes = await buildPdfBytes(<PdfPageSource>[
      PdfPageSource(
        imageBytes: tinyPng(20, 20),
        widthPx: 20,
        heightPx: 20,
        strokes: const <Stroke>[],
      ),
    ]);
    final tmp = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}mmb_pdf_test.pdf');
    await tmp.writeAsBytes(bytes, flush: true);
    final first = tmp.readAsBytesSync().first;
    expect(first, 0x25); // '%'
    await tmp.delete();
  });
}
