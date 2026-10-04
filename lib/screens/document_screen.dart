import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/music_document.dart';
import '../models/music_page.dart';
import '../screens/camera_screen.dart';
import '../screens/viewer_screen.dart';
import '../state/app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/edge_swipe_back.dart';
import '../widgets/pdf_actions.dart';

class DocumentScreen extends StatefulWidget {
  const DocumentScreen({super.key, required this.document});

  static const String routeName = '/document';

  final MusicDocument document;

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends State<DocumentScreen> {
  /// 並び替えモード中の並び (null = 通常表示)。「完了」まで保存しない。
  List<MusicPage>? _reorder;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().reloadPages(widget.document.id);
  }

  Future<void> _addPages() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CameraScreen(document: widget.document)),
    );
    if (mounted) {
      await context.read<AppState>().reloadPages(widget.document.id);
      setState(() {});
    }
  }

  Future<void> _deletePage(MusicPage page) async {
    final ok = await showConfirmDialog(
      context,
      'ページを削除',
      '${page.index + 1}ページ目とその手書きメモを削除します。',
    );
    if (!ok || !mounted) return;
    await context.read<AppState>().deletePage(page);
    if (mounted) setState(() {});
  }

  void _showPageActions(int index, int total, MusicPage page) {
    final app = context.read<AppState>();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.sticky_note_2_outlined),
              title: const Text('ページメモを編集'),
              subtitle: Text(
                page.note.isEmpty ? '(検索Index用のメモなし)' : page.note,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () async {
                Navigator.of(ctx).pop();
                final note = await showNoteDialog(context, page.note);
                if (note != null) {
                  await app.setPageNote(page, note);
                  if (mounted) setState(() {});
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: const Text('前へ移動'),
              enabled: index > 0,
              onTap: () async {
                Navigator.of(ctx).pop();
                await app.movePage(page, -1);
                if (mounted) setState(() {});
              },
            ),
            ListTile(
              leading: const Icon(Icons.arrow_downward),
              title: const Text('後へ移動'),
              enabled: index < total - 1,
              onTap: () async {
                Navigator.of(ctx).pop();
                await app.movePage(page, 1);
                if (mounted) setState(() {});
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text('削除',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () {
                Navigator.of(ctx).pop();
                _deletePage(page);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 並び替え

  void _startReorder() {
    final pages = context.read<AppState>().cachedPages(widget.document.id) ??
        const <MusicPage>[];
    setState(() => _reorder = List<MusicPage>.of(pages));
  }

  bool get _reorderChanged {
    final list = _reorder;
    if (list == null) return false;
    for (int i = 0; i < list.length; i++) {
      if (list[i].index != i) return true;
    }
    return false;
  }

  void _moveInReorder(int from, int to) {
    setState(() {
      final list = _reorder!;
      list.insert(to, list.removeAt(from));
    });
  }

  Future<void> _finishReorder() async {
    final list = _reorder;
    if (list == null) return;
    if (_reorderChanged) {
      await context.read<AppState>().reorderPages(widget.document, list);
      if (mounted) showSnackBar(context, '並び順を保存しました');
    }
    if (mounted) setState(() => _reorder = null);
  }

  /// 変更があれば確認してから並び替えモードを抜ける (保存しない)。
  Future<void> _cancelReorder() async {
    if (_reorderChanged) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('並び替えをやめますか？'),
          content: const Text('入れ替えた順番は保存されません。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('続ける'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存せずに戻る'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    if (mounted) setState(() => _reorder = null);
  }

  Widget _buildReorderList(ThemeData theme, List<MusicPage> list) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'ドラッグして順番を入れ替え、「完了」で保存します',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            itemCount: list.length,
            onReorderItem: _moveInReorder,
            itemBuilder: (context, i) {
              final p = list[i];
              final moved = p.index != i;
              return ReorderableDelayedDragStartListener(
                key: ValueKey<String>(p.id),
                index: i,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                    child: Row(
                      children: <Widget>[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: SizedBox(
                            width: 66,
                            height: 88,
                            child: Image.file(
                              File(p.thumbPath),
                              fit: BoxFit.cover,
                              cacheWidth: 160,
                              errorBuilder: (_, _, _) => Container(
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: const Icon(Icons.broken_image_outlined),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text('${i + 1}ページ目',
                                  style: theme.textTheme.titleMedium),
                              if (moved)
                                Text('元は ${p.index + 1}ページ目',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.primary)),
                            ],
                          ),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.all(16),
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _showDocumentMenu() {
    final app = context.read<AppState>();
    final pageCount = app.cachedPages(widget.document.id)?.length ?? 0;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.swap_vert),
              title: const Text('ページを並び替え'),
              enabled: pageCount >= 2,
              onTap: () {
                Navigator.of(ctx).pop();
                _startReorder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf),
              title: const Text('PDF に書き出す (手書きメモ込み)'),
              onTap: () {
                Navigator.of(ctx).pop();
                promptPdfExport(context, document: widget.document);
              },
            ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('タグを編集'),
              subtitle: Text(
                widget.document.tags.isEmpty
                    ? '検索用のタグなし'
                    : widget.document.tags.join(' / '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () async {
                Navigator.of(ctx).pop();
                final raw =
                    await showTagsDialog(context, widget.document.tags);
                if (raw != null) {
                  await app.setDocumentTags(widget.document, raw.split(','));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('名前を変更'),
              onTap: () async {
                Navigator.of(ctx).pop();
                final newTitle =
                    await showRenameDialog(context, widget.document.title);
                if (newTitle != null) {
                  await app.renameDocument(widget.document, newTitle);
                  if (mounted) setState(() {});
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text('教材を削除',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () async {
                Navigator.of(ctx).pop();
                final ok = await showConfirmDialog(
                  context,
                  '教材を削除',
                  '「${widget.document.title}」の全ページと手書きメモを削除します。元に戻せません。',
                );
                if (ok && mounted) {
                  await app.deleteDocument(widget.document);
                  if (mounted) Navigator.of(context).pop();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pages = app.cachedPages(widget.document.id) ?? const <MusicPage>[];
    final theme = Theme.of(context);
    final reorder = _reorder;

    // 並び替え中の戻る操作は「並び替えをやめる」(画面は閉じない)
    return PopScope(
      canPop: reorder == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _reorder != null) _cancelReorder();
      },
      child: EdgeSwipeBack(
        label: 'ホームに戻る',
        enabled: reorder == null,
        child: Scaffold(
          appBar: reorder != null
              ? _buildReorderAppBar()
              : _buildAppBar(app, theme),
          body: reorder != null
              ? _buildReorderList(theme, reorder)
              : _buildPages(theme, pages),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildReorderAppBar() => AppBar(
        leading: IconButton(
          tooltip: '並び替えをやめる',
          icon: const Icon(Icons.close),
          onPressed: _cancelReorder,
        ),
        title: const Text('ページを並び替え'),
        actions: <Widget>[
          TextButton(
            onPressed: _finishReorder,
            child: const Text('完了'),
          ),
        ],
      );

  PreferredSizeWidget _buildAppBar(AppState app, ThemeData theme) => AppBar(
        title: GestureDetector(
          onTap: () async {
            final newTitle =
                await showRenameDialog(context, widget.document.title);
            if (newTitle != null) {
              await app.renameDocument(widget.document, newTitle);
            }
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: Text(
                  widget.document.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.edit_outlined,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: 'さらにスキャン',
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: _addPages,
          ),
          IconButton(
            tooltip: 'メニュー',
            icon: const Icon(Icons.more_vert),
            onPressed: _showDocumentMenu,
          ),
        ],
      );

  Widget _buildPages(ThemeData theme, List<MusicPage> pages) {
    if (pages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.photo_library_outlined,
                size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            const Text('まだページがありません'),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.photo_camera),
              label: const Text('スキャンする'),
              onPressed: _addPages,
            ),
          ],
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        childAspectRatio: 0.74,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: pages.length,
      itemBuilder: (context, i) => _PageTile(
        page: pages[i],
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ViewerScreen(
                document: widget.document,
                initialIndex: i,
              ),
            ),
          );
        },
        onLongPress: () => _showPageActions(i, pages.length, pages[i]),
      ),
    );
  }
}

class _PageTile extends StatelessWidget {
  const _PageTile({
    required this.page,
    required this.onTap,
    required this.onLongPress,
  });

  final MusicPage page;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final hasMemo = page.strokes.isNotEmpty;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Image.file(
              File(page.thumbPath),
              fit: BoxFit.cover,
              cacheWidth: 380,
              errorBuilder: (_, _, _) => Container(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
            Positioned(
              left: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${page.index + 1}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
            if (hasMemo)
              const Positioned(
                right: 6,
                top: 6,
                child: Icon(Icons.edit_note, size: 18, color: Colors.amber),
              ),
            if (page.note.isNotEmpty)
              Positioned(
                right: hasMemo ? 26 : 6,
                top: 6,
                child: const Icon(Icons.sticky_note_2,
                    size: 16, color: Colors.lightGreenAccent),
              ),
          ],
        ),
      ),
    );
  }
}
