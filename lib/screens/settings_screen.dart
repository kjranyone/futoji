import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../screens/about_screen.dart';
import '../services/backup_service.dart';
import '../services/self_test.dart';
import '../services/training_capture.dart';
import '../state/app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/edge_swipe_back.dart';

/// 設定画面。バックアップの書き出し・復元と、開発者向けの機能
/// (検出改善データの保存・自己診断) の切り替え。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<void> _setTrainingCapture(bool value) async {
    await TrainingCapture.setEnabled(value);
    if (!mounted) return;
    setState(() {});
    if (!value) {
      showSnackBar(context, '切り抜き結果の保存をオフにしました');
      return;
    }
    final dir = await TrainingCapture.directory();
    final n = await TrainingCapture.count();
    if (!mounted) return;
    showSnackBar(context, '保存オン ($n 件保存済み): ${dir.path}');
  }

  /// 処理中はダイアログで操作を止める (戻るボタンも無効)。
  Future<T> _withProgress<T>(String message, Future<T> Function() task) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: <Widget>[
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
    try {
      return await task();
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// 作成前に件数と予想サイズを見せ、空き容量が足りなければ止める。
  Future<bool> _confirmExport() async {
    final est = BackupService.estimate();
    if (est.pageCount == 0) {
      showSnackBar(context, '書き出す教材がありません');
      return false;
    }
    // zip はいったんアプリの一時領域に作るので、その空き容量を確認する (Android のみ取得)
    int? free;
    if (Platform.isAndroid) {
      try {
        free = await _saveChannel.invokeMethod<int>('freeBytes');
      } catch (_) {}
    }
    if (!mounted) return false;
    // 一時領域の zip に加え、端末内に保存するとその分も要るので余裕を見て 2 倍 + 50 MB
    final need = est.bytes * 2 + 50 * 1024 * 1024;
    final short = free != null && free < need;
    final theme = Theme.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('バックアップを書き出す'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('教材 ${est.documentCount} 件・${est.pageCount} ページ'),
            const SizedBox(height: 4),
            Text('予想サイズ: 約 ${formatBytes(est.bytes)}',
                style: theme.textTheme.titleMedium),
            if (free != null) ...<Widget>[
              const SizedBox(height: 4),
              Text('端末の空き容量: ${formatBytes(free)}',
                  style: theme.textTheme.bodySmall),
            ],
            if (est.missingImages > 0) ...<Widget>[
              const SizedBox(height: 8),
              Text('画像が見つからない ${est.missingImages} ページは含まれません',
                  style: theme.textTheme.bodySmall),
            ],
            if (short) ...<Widget>[
              const SizedBox(height: 8),
              Text('空き容量が足りません (約 ${formatBytes(need)} 必要)。'
                  '不要なファイルを削除してから書き出してください',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: short ? null : () => Navigator.of(ctx).pop(true),
            child: const Text('作成'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _exportBackup() async {
    if (!await _confirmExport() || !mounted) return;
    try {
      final result = await _withProgress('バックアップを作成中…', BackupService.export);
      if (!mounted) return;
      final size = formatBytes(await result.file.length());
      if (!mounted) return;
      final summary = '教材 ${result.documentCount} 件・${result.pageCount} ページ・$size';
      final missing = result.missingImages > 0
          ? ' (画像が見つからない ${result.missingImages} ページは含めていません)'
          : '';
      // iOS は共有シートに「ファイルに保存」があるので共有だけ。Android は共有先に
      // 保存アプリが無い端末もあるため、保存先を選ぶ (SAF) か共有かを選んでもらう。
      final how = Platform.isAndroid ? await _askExportTarget(summary) : 'share';
      if (how == null || !mounted) return;
      if (how == 'save') {
        final name = result.file.uri.pathSegments.last;
        final saved = await _saveChannel.invokeMethod<bool>('saveAs', <String, String>{
          'path': result.file.path,
          'name': name,
          'mimeType': 'application/zip',
        });
        if (saved == true && mounted) {
          showSnackBar(context, 'バックアップを保存しました ($summary)$missing');
        }
        return;
      }
      if (missing.isNotEmpty) showSnackBar(context, missing.trim());
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(result.file.path, mimeType: 'application/zip')],
          text: 'MusicBook のバックアップ ($summary)',
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showSnackBar(context, 'バックアップの作成に失敗しました: $e');
    }
  }

  static const MethodChannel _saveChannel = MethodChannel('mymusicbook/save');

  /// 書き出した zip の渡し先を選ぶ ('save' / 'share' / キャンセルで null)。
  Future<String?> _askExportTarget(String summary) => showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(title: Text('バックアップを作成しました ($summary)')),
              ListTile(
                leading: const Icon(Icons.save_alt_outlined),
                title: const Text('保存先を選んで保存'),
                subtitle: const Text('端末内のフォルダや Google ドライブなど'),
                onTap: () => Navigator.of(ctx).pop('save'),
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('他のアプリで共有'),
                onTap: () => Navigator.of(ctx).pop('share'),
              ),
            ],
          ),
        ),
      );

  Future<void> _restoreBackup() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('バックアップから復元'),
        content: const Text('バックアップ (zip) の教材を読み込みます。\n'
            '同じ教材が端末にある場合はバックアップの内容で置き換え、'
            'それ以外の教材はそのまま残します。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ファイルを選ぶ'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>['zip'],
    );
    if (picked == null || !mounted) return;
    final app = context.read<AppState>();
    File? copy;
    try {
      final result = await _withProgress('復元中…', () async {
        // Android の選択結果は content:// のことがあるので、いったん一時ファイルに写す
        final tmp = await getTemporaryDirectory();
        copy = File('${tmp.path}${Platform.pathSeparator}restore_source.zip');
        final sink = copy!.openWrite();
        await sink.addStream(picked.readAsByteStream());
        await sink.close();
        final r = await BackupService.restore(copy!.path);
        await app.reloadAll();
        return r;
      });
      if (!mounted) return;
      final skipped = result.skippedPages > 0 ? ' (${result.skippedPages} ページは画像が無く省略)' : '';
      showSnackBar(context,
          '教材 ${result.documentCount} 件・${result.pageCount} ページを復元しました$skipped');
    } on FormatException catch (e) {
      if (!mounted) return;
      showSnackBar(context, '復元できません: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      showSnackBar(context, '復元に失敗しました: $e');
    } finally {
      try {
        await copy?.delete();
      } catch (_) {}
    }
  }

  Future<void> _setSelfTest(bool value) async {
    await SelfTest.setEnabled(value);
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return EdgeSwipeBack(
      label: 'ホームに戻る',
      child: Scaffold(
        appBar: AppBar(title: const Text('設定')),
        body: ListView(
          children: <Widget>[
            _sectionHeader(theme, 'バックアップ'),
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: const Text('バックアップを書き出す'),
              subtitle: const Text('全教材 (画像・手書きメモ・タグ) を zip にまとめ、'
                  '端末のフォルダや Google ドライブなどに保存します'),
              onTap: _exportBackup,
            ),
            ListTile(
              leading: const Icon(Icons.restore_outlined),
              title: const Text('バックアップから復元'),
              subtitle: const Text('書き出した zip から教材を読み込みます'),
              onTap: _restoreBackup,
            ),
            const Divider(),
            _sectionHeader(theme, '画質'),
            SwitchListTile(
              secondary: const Icon(Icons.auto_awesome_outlined),
              title: const Text('AI でくっきり'),
              subtitle: const Text('撮影した紙面のぼけ・ノイズを AI で取り、文字や音符を'
                  'シャープにして保存します。端末内で処理し、1 ページに 10 秒ほどかかります'),
              value: context.watch<AppState>().aiSharpen,
              onChanged: (v) => context.read<AppState>().setAiSharpen(v),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('このアプリについて'),
              subtitle: const Text('バージョン・プライバシーポリシー・ライセンス'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
              ),
            ),
            const Divider(),
            _sectionHeader(theme, '開発者向け'),
            SwitchListTile(
              title: const Text('検出改善用に切り抜き結果を保存'),
              subtitle: const Text('撮影画像と四隅を端末のアプリ領域に保存します。'
                  '紙面検出の学習・評価に使います'),
              value: TrainingCapture.enabled,
              onChanged: _setTrainingCapture,
            ),
            SwitchListTile(
              title: const Text('紙面検出の自己診断を許可'),
              subtitle: const Text('./dev.ps1 selftest が置いた画像で、'
                  '起動時に検出の速度と精度を測ります'),
              value: SelfTest.enabled,
              onChanged: _setSelfTest,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(label,
            style: theme.textTheme.titleSmall
                ?.copyWith(color: theme.colorScheme.primary)),
      );
}
