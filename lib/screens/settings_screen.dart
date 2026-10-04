import 'package:flutter/material.dart';

import '../services/self_test.dart';
import '../services/training_capture.dart';
import '../widgets/dialogs.dart';

/// 設定画面。開発者向けの機能 (検出改善データの保存・自己診断) はここで ON にする。
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

  Future<void> _setSelfTest(bool value) async {
    await SelfTest.setEnabled(value);
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: <Widget>[
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('オープンソースライセンス'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'MusicBook',
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('開発者向け',
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: theme.colorScheme.primary)),
          ),
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
    );
  }
}
