import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/music_document.dart';
import '../services/pdf_export.dart';
import '../state/app_state.dart';
import 'dialogs.dart';

/// PDF 書き出し → 共有シートまでの一連の流れ。
/// 進捗ダイアログを出し、完了したら OS の共有シートを開く。
Future<void> promptPdfExport(
  BuildContext context, {
  required MusicDocument document,
}) async {
  final app = context.read<AppState>();
  final pages = await app.pagesOf(document.id);
  if (!context.mounted) return;
  if (pages.isEmpty) {
    showSnackBar(context, 'ページがありません。先にスキャンしてください。');
    return;
  }

  final progress = ValueNotifier<int>(0);
  late final Future<PdfExportResult> future;
  // ignore: unawaited_futures
  future = exportDocumentPdf(
    title: document.title,
    pages: pages,
    onProgress: (done, total) => progress.value = done,
  );

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('PDF を生成中…'),
      content: ValueListenableBuilder<int>(
        valueListenable: progress,
        builder: (_, v, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LinearProgressIndicator(
              value: v / pages.length,
            ),
            const SizedBox(height: 10),
            Text('$v / ${pages.length} ページ'),
          ],
        ),
      ),
    ),
  );

  try {
    final result = await future;
    if (!context.mounted) return;
    Navigator.of(context).pop(); // 進捗ダイアログを閉じる
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(result.file.path, mimeType: 'application/pdf')],
        text: '${document.title} (${result.pageCount}ページ・手書きメモ込み)',
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    Navigator.of(context).pop();
    showSnackBar(context, 'PDF の生成に失敗しました: $e');
  } finally {
    progress.dispose();
  }
}
