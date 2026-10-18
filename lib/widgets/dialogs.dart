import 'package:flutter/material.dart';

import '../models/music_document.dart';

/// 共通ダイアログ。
Future<String?> showRenameDialog(BuildContext context, String current) {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('名前を変更'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 60,
        decoration: const InputDecoration(hintText: '例) バイオリン教室・基礎テキスト'),
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

/// ページメモ編集ダイアログ (複数行)。
Future<String?> showNoteDialog(BuildContext context, String current) {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('ページメモ'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: 4,
        maxLength: 500,
        decoration: const InputDecoration(
          hintText: '例) 3ページ目の音階練習 / ここで転調',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

/// 教材タグ編集ダイアログ (カンマ区切り)。
Future<String?> showTagsDialog(BuildContext context, List<String> current) {
  final controller = TextEditingController(text: current.join(', '));
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('タグを編集'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 200,
        decoration: const InputDecoration(
          hintText: 'カンマ区切り: 音階, 基礎, 発表会',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text),
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

Future<bool> showConfirmDialog(
  BuildContext context,
  String title,
  String message,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('キャンセル'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('削除'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// ブックの削除確認。消えるページ数を示す。
Future<bool> confirmDeleteBook(BuildContext context, MusicDocument doc) => showConfirmDialog(
      context,
      'ブックを削除',
      '「${doc.title}」の ${doc.pageCount} ページと手書きメモをすべて削除します。元に戻せません。',
    );

/// [bottomMargin] を渡すと画面の下から浮かせて出す
/// (カメラのシャッターなど、下にある操作に被せたくない画面用)。
void showSnackBar(BuildContext context, String message, {double? bottomMargin}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
      behavior: bottomMargin == null ? null : SnackBarBehavior.floating,
      margin: bottomMargin == null ? null : EdgeInsets.fromLTRB(16, 0, 16, bottomMargin),
    ));
}
