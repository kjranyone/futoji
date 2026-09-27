import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/music_document.dart';
import '../models/music_page.dart';
import '../screens/camera_screen.dart';
import '../screens/viewer_screen.dart';
import '../state/app_state.dart';
import '../widgets/dialogs.dart';
import '../widgets/pdf_actions.dart';

class DocumentScreen extends StatefulWidget {
  const DocumentScreen({super.key, required this.document});

  static const String routeName = '/document';

  final MusicDocument document;

  @override
  State<DocumentScreen> createState() => _DocumentScreenState();
}

class _DocumentScreenState extends State<DocumentScreen> {
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

  void _showDocumentMenu() {
    final app = context.read<AppState>();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
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

    return Scaffold(
      appBar: AppBar(
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
            icon: const Icon(Icons.more_vert),
            onPressed: _showDocumentMenu,
          ),
        ],
      ),
      body: pages.isEmpty
          ? Center(
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
            )
          : GridView.builder(
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
                onLongPress: () =>
                    _showPageActions(i, pages.length, pages[i]),
              ),
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
