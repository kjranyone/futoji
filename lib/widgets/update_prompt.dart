import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/update_checker.dart';

/// 新しいバージョンの案内。ダウンロードはブラウザで GitHub のリリースページを開いて行う。
Future<void> showUpdateDialog(BuildContext context, ReleaseInfo release) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('新しいバージョンがあります'),
      content: Text('バージョン ${release.version} が公開されています。\n\n'
          'ダウンロードページで arm64-v8a の APK をダウンロードしてインストールしてください。'
          '上書きでインストールすると、ブックやメモはそのまま残ります。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('あとで'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            launchUrl(Uri.parse(release.pageUrl), mode: LaunchMode.externalApplication);
          },
          child: const Text('ダウンロードページを開く'),
        ),
      ],
    ),
  );
}

/// 起動時の自動確認。新しい版があれば下に知らせを出す (確認は 1 日 1 回まで)。
Future<void> autoCheckForUpdate(BuildContext context) async {
  final release = await UpdateChecker.autoCheck();
  if (release == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('新しいバージョン ${release.version} があります'),
    duration: const Duration(seconds: 8),
    action: SnackBarAction(
      label: '詳しく',
      onPressed: () {
        if (context.mounted) showUpdateDialog(context, release);
      },
    ),
  ));
}
