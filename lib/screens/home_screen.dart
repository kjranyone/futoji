import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/music_document.dart';
import '../screens/camera_screen.dart';
import '../screens/document_screen.dart';
import '../screens/settings_screen.dart';
import '../services/db_service.dart';
import '../services/search.dart';
import '../services/update_checker.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/dialogs.dart';
import '../widgets/image_fade_in.dart';
import '../widgets/update_prompt.dart';

/// ブック一覧。ブック一覧・ページ一覧・ビューアは黒背景で揃える。
/// テーマは画面の外側に置く (内側だと、ここから開くダイアログやメニューに届かない)。
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      Theme(data: buildBrowseTheme(), child: const _HomeView());
}

class _HomeView extends StatefulWidget {
  const _HomeView();

  @override
  State<_HomeView> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeView> {
  bool _searching = false;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (UpdateChecker.available) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) autoCheckForUpdate(context);
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<MusicDocument> _filter(List<MusicDocument> docs) {
    final q = _query.trim();
    if (q.isEmpty) return docs;
    // タイトル + タグ + ページメモを横断検索する
    return docs.where((d) {
      final pages =
          DbService.pages.values.where((p) => p.documentId == d.id);
      return DocSearch.matches(d, pages, q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '教材名で検索',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : const Text('全てのブック',
                style: TextStyle(fontWeight: FontWeight.w700)),
        centerTitle: false,
        actions: <Widget>[
          IconButton(
            tooltip: _searching ? '検索を閉じる' : '検索',
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _query = '';
                  _searchController.clear();
                }
              });
            },
          ),
          IconButton(
            tooltip: '設定',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Consumer<AppState>(
        builder: (context, app, _) {
          final all = app.documents;
          if (all.isEmpty) {
            return const _EmptyState();
          }
          final docs = _filter(all);
          if (docs.isEmpty) {
            return Center(
              child: Text(
                '「$_query」に一致する教材はありません',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              childAspectRatio: 0.72,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: docs.length,
            itemBuilder: (context, i) {
              final q = _query.trim();
              final reason = q.isEmpty
                  ? ''
                  : DocSearch.matchReason(
                      docs[i],
                      DbService.pages.values
                          .where((p) => p.documentId == docs[i].id),
                      q,
                    );
              return _DocumentCard(doc: docs[i], searchReason: reason);
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'home-scan',
        icon: const Icon(Icons.photo_camera),
        label: const Text('スキャン'),
        onPressed: () => _startScan(context),
      ),
    );
  }

  Future<void> _startScan(BuildContext context) async {
    final app = context.read<AppState>();
    final doc = await app.createDocument();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CameraScreen(document: doc)),
    );
    // 1 ページも撮らずに閉じたら空の教材を残さない
    final pages = await app.pagesOf(doc.id);
    if (pages.isEmpty) {
      await app.deleteDocument(doc);
    } else {
      await app.refreshDocuments();
    }
  }
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({required this.doc, this.searchReason = ''});

  final MusicDocument doc;

  /// 検索で一致した理由 ('タイトル' / 'タグ' / 'ページメモ')。未検索時は空。
  final String searchReason;

  void _showActions(BuildContext context, AppState app) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('タグを編集'),
              subtitle: Text(
                doc.tags.isEmpty ? '検索用のタグなし' : doc.tags.join(' / '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () async {
                Navigator.of(ctx).pop();
                final raw = await showTagsDialog(context, doc.tags);
                if (raw != null) {
                  await app.setDocumentTags(doc, raw.split(','));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('名前を変更'),
              onTap: () async {
                Navigator.of(ctx).pop();
                final newTitle =
                    await showRenameDialog(context, doc.title);
                if (newTitle != null) await app.renameDocument(doc, newTitle);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text('削除',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () async {
                Navigator.of(ctx).pop();
                final ok = await confirmDeleteBook(context, doc);
                if (ok) await app.deleteDocument(doc);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final cover = doc.coverThumbPath;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DocumentScreen(document: doc),
            ),
          );
        },
        onLongPress: () => _showActions(context, app),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: cover != null
                  ? Image.file(
                      File(cover),
                      fit: BoxFit.cover,
                      cacheWidth: 420,
                      frameBuilder: fadeInImageFrame,
                      errorBuilder: (_, _, _) => const _CoverPlaceholder(),
                    )
                  : const _CoverPlaceholder(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    doc.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (doc.tags.isNotEmpty)
                    Text(
                      doc.tags.join(' / '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  if (searchReason.isNotEmpty && searchReason != 'タイトル')
                    Text(
                      '🔍 $searchReason で一致',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.tertiary,
                          ),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    '${doc.pageCount}ページ・${formatDateTime(doc.updatedAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.music_note,
          size: 48,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.auto_stories,
                size: 72,
                color: theme.colorScheme.primary.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text('教材をスキャンして保存', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '右下の「スキャン」から楽譜やプリントを\nカメラで読み取れます。\n紙面は自動で検出・補正され、WebPで保存されます。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
