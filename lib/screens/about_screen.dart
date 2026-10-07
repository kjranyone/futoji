import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';

import '../widgets/edge_swipe_back.dart';

/// 「このアプリについて」: アプリ名・バージョン・説明・プライバシーポリシー・ライセンス。
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String appName = 'MusicBook';
  static const String sourceUrl = 'https://github.com/kjranyone/mymusicbook';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return EdgeSwipeBack(
      label: '設定に戻る',
      child: Scaffold(
        appBar: AppBar(title: const Text('このアプリについて')),
        body: ListView(
          children: <Widget>[
            const SizedBox(height: 32),
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Image.asset('assets/branding/about_icon.png', width: 96, height: 96),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(appName,
                  style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 4),
            Center(
              child: FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snap) {
                  final info = snap.data;
                  return Text(
                    info == null ? ' ' : 'バージョン ${info.version} (${info.buildNumber})',
                    key: const ValueKey<String>('about-version'),
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                '音楽教室の楽譜やプリントをカメラで取り込み、教材ごとに整理して閲覧するアプリです。'
                '撮影した資料と手書きメモは端末の中だけに保存されます。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 24),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('プライバシーポリシー'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('オープンソースライセンス'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(context: context, applicationName: appName),
            ),
            const ListTile(
              leading: Icon(Icons.code),
              title: Text('ソースコード'),
              subtitle: SelectableText(sourceUrl),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Text(
                '© 2026 kjranyone\nMIT License',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// プライバシーポリシーの全文 (docs/PRIVACY_POLICY.md を同梱して表示する)。
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const String assetPath = 'docs/PRIVACY_POLICY.md';

  @override
  Widget build(BuildContext context) {
    return EdgeSwipeBack(
      label: '戻る',
      child: Scaffold(
        appBar: AppBar(title: const Text('プライバシーポリシー')),
        body: FutureBuilder<String>(
          future: rootBundle.loadString(assetPath),
          builder: (context, snap) {
            final text = snap.data;
            if (text == null) {
              return const Center(child: CircularProgressIndicator());
            }
            return SelectionArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
                children: buildSimpleMarkdown(context, text),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// ポリシー文書に使っている範囲だけの簡易 Markdown 表示
/// (見出し・箇条書き・表・**強調**・`コード`)。
List<Widget> buildSimpleMarkdown(BuildContext context, String markdown) {
  final theme = Theme.of(context);
  final widgets = <Widget>[];
  final paragraph = <String>[];
  final table = <List<String>>[];
  String? bullet; // 書きかけの箇条書き (字下げした続きの行を足していく)

  void flushBullet() {
    final text = bullet;
    if (text == null) return;
    widgets.add(Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('・'),
          Expanded(child: Text.rich(_inline(text, theme.textTheme.bodyMedium!))),
        ],
      ),
    ));
    bullet = null;
  }

  void flushParagraph() {
    flushBullet();
    if (paragraph.isEmpty) return;
    // 文書の改行は見た目の折り返しなので、日本語の文としてそのままつなげる
    widgets.add(Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text.rich(_inline(paragraph.join(), theme.textTheme.bodyMedium!)),
    ));
    paragraph.clear();
  }

  void flushTable() {
    if (table.isEmpty) return;
    final header = table.first;
    // 狭い画面でも読めるよう、表は行ごとに「見出し: 値」のカードにする
    for (final row in table.skip(1)) {
      widgets.add(Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < row.length && i < header.length; i++)
              Text.rich(TextSpan(children: <InlineSpan>[
                TextSpan(
                    text: '${header[i]}: ',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                _inline(row[i], theme.textTheme.bodyMedium!),
              ])),
          ],
        ),
      ));
    }
    table.clear();
  }

  for (final raw in markdown.split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('|')) {
      flushParagraph();
      final cells = line.split('|').map((c) => c.trim()).toList();
      final row = cells.sublist(1, cells.length - 1);
      if (row.every((c) => RegExp(r'^:?-+:?$').hasMatch(c))) continue; // 区切り行
      table.add(row);
      continue;
    }
    flushTable();
    if (line.trim().isEmpty) {
      flushParagraph();
      continue;
    }
    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      flushParagraph();
      final level = heading.group(1)!.length;
      final style = level == 1
          ? theme.textTheme.headlineSmall
          : (level == 2 ? theme.textTheme.titleMedium : theme.textTheme.titleSmall);
      widgets.add(Padding(
        padding: EdgeInsets.only(top: level == 1 ? 0 : 14, bottom: 8),
        child: Text(heading.group(2)!, style: style?.copyWith(fontWeight: FontWeight.w700)),
      ));
      continue;
    }
    final item = RegExp(r'^\s*[-*]\s+(.*)$').firstMatch(line);
    if (item != null) {
      flushParagraph();
      bullet = item.group(1)!;
      continue;
    }
    if (bullet != null && line.startsWith('  ')) {
      bullet = '$bullet${line.trim()}'; // 箇条書きの続きの行
      continue;
    }
    flushBullet();
    paragraph.add(line.trim());
  }
  flushTable();
  flushParagraph();
  return widgets;
}

/// **強調** と `コード` だけを解釈する。
TextSpan _inline(String text, TextStyle base) {
  final spans = <InlineSpan>[];
  final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
  var last = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
    if (m.group(1) != null) {
      spans.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700)));
    } else {
      spans.add(TextSpan(
          text: m.group(2), style: const TextStyle(fontFamily: 'monospace', fontSize: 13)));
    }
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return TextSpan(style: base, children: spans);
}
