import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/music_document.dart';
import '../models/music_page.dart';
import '../models/stroke.dart';
import '../screens/camera_screen.dart';
import '../state/app_state.dart';
import '../widgets/corner_overlay.dart';
import '../widgets/dialogs.dart';
import '../widgets/edge_swipe_back.dart';
import '../widgets/pdf_actions.dart';
import '../widgets/stroke_layer.dart';

/// 全画面ブラウズ。横スワイプでページ送り、手書きメモを重ねられる。
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({
    super.key,
    required this.document,
    required this.initialIndex,
  });

  final MusicDocument document;
  final int initialIndex;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late final PageController _pageController;
  int _index = 0;

  /// 中央タップで上下のバーを隠す (楽譜を画面いっぱいに見る)。
  bool _chromeHidden = false;

  bool _drawMode = false;
  bool _showStrokes = true;
  bool _eraser = false;
  int _penColor = 0xFFE53935;
  double _penWidth = 0.006;

  static const List<int> _colors = <int>[
    0xFF212121,
    0xFFE53935,
    0xFF1E88E5,
  ];
  static const List<(String, double)> _widths = <(String, double)>[
    ('細', 0.004),
    ('中', 0.007),
    ('太', 0.012),
  ];

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    context.read<AppState>().reloadPages(widget.document.id);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
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

  Future<void> _deleteCurrent(List<MusicPage> pages) async {
    if (pages.isEmpty) return;
    final page = pages[_index.clamp(0, pages.length - 1)];
    final ok = await showConfirmDialog(
        context, 'ページを削除', '${page.index + 1}ページ目とその手書きメモを削除します。');
    if (!ok || !mounted) return;
    await context.read<AppState>().deletePage(page);
    if (!mounted) return;
    final app = context.read<AppState>();
    final remaining = await app.reloadPages(widget.document.id);
    if (!mounted) return;
    if (remaining.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _index = _index.clamp(0, remaining.length - 1);
      _pageController.jumpToPage(_index);
    });
  }

  /// undo 履歴 (ストロークリストのスナップショット)。ページ送りでリセット。
  final List<List<Stroke>> _undoStack = <List<Stroke>>[];

  void _pushUndo(MusicPage page) {
    _undoStack.add(snapshotStrokes(page.strokes));
    if (_undoStack.length > kMaxUndoSteps) {
      _undoStack.removeAt(0);
    }
  }

  void _onStrokeEnd(MusicPage page, Stroke stroke) {
    _pushUndo(page);
    page.strokes.add(stroke);
    context.read<AppState>().saveStrokes(page);
    setState(() {});
  }

  /// 消しゴム操作の開始時に現在状態を履歴へ退避する。
  void _onEraseStart(MusicPage page) {
    _pushUndo(page);
  }

  void _onEraseEnd(MusicPage page) {
    context.read<AppState>().saveStrokes(page);
    setState(() {});
  }

  void _undo(MusicPage page) {
    if (_undoStack.isEmpty) return;
    page.strokes = _undoStack.removeLast();
    context.read<AppState>().saveStrokes(page);
    setState(() {});
  }

  /// 漫画ビューアのようなタップ操作: 左 1/3 で前、右 1/3 で次のページ、中央でバーの表示切替。
  void _onTapZone(double fx, int total) {
    switch (tapZoneOf(fx)) {
      case TapZone.previous:
        if (_index <= 0) {
          showSnackBar(context, '最初のページです');
          return;
        }
        _pageController.previousPage(
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      case TapZone.next:
        if (_index >= total - 1) {
          showSnackBar(context, '最後のページです');
          return;
        }
        _pageController.nextPage(
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      case TapZone.center:
        setState(() => _chromeHidden = !_chromeHidden);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pages = app.cachedPages(widget.document.id) ?? const <MusicPage>[];
    final showChrome = !_chromeHidden || _drawMode;

    // 手書き中は端からのスワイプで戻らない (端の近くに書けるように)。
    // 戻る操作 (ボタン・システムの戻る) は「閲覧に戻る」として扱う。
    return PopScope(
      canPop: !_drawMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_drawMode) return;
        setState(() {
          _drawMode = false;
          _eraser = false;
        });
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: !showChrome
            ? null
            : AppBar(
                backgroundColor: Colors.black87,
                foregroundColor: Colors.white,
                title: Text(
                  pages.isEmpty ? '-' : '${_index + 1} / ${pages.length}',
                  style: const TextStyle(fontSize: 15),
                ),
                actions: <Widget>[
                  IconButton(
                    tooltip: _showStrokes ? 'メモを隠す' : 'メモを表示',
                    icon: Icon(_showStrokes ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _showStrokes = !_showStrokes),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    onPressed: _addPages,
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'pdf') {
                        promptPdfExport(context, document: widget.document);
                      } else if (v == 'note') {
                        if (pages.isEmpty) return;
                        final app = context.read<AppState>();
                        final page = pages[_index.clamp(0, pages.length - 1)];
                        final note = await showNoteDialog(context, page.note);
                        if (note != null && mounted) {
                          await app.setPageNote(page, note);
                          if (mounted) setState(() {});
                        }
                      } else if (v == 'delete') {
                        _deleteCurrent(pages);
                      }
                    },
                    itemBuilder: (_) => <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'note',
                        enabled: pages.isNotEmpty,
                        child: ListTile(
                          leading: Icon(Icons.sticky_note_2_outlined),
                          title: Text('ページメモを編集'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem<String>(
                        value: 'pdf',
                        child: ListTile(
                          leading: Icon(Icons.picture_as_pdf),
                          title: Text('PDF に書き出す'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem<String>(
                        value: 'delete',
                        child: ListTile(
                          leading: Icon(Icons.delete_outline),
                          title: Text('このページを削除'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
        body: pages.isEmpty
            ? const Center(
                child: Text('ページがありません', style: TextStyle(color: Colors.white54)))
            : EdgeSwipeBack(
                label: '一覧に戻る',
                enabled: !_drawMode,
                child: PageView.builder(
                  controller: _pageController,
                  physics: _drawMode
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemCount: pages.length,
                  onPageChanged: (i) {
                    setState(() {
                      _index = i;
                      _undoStack.clear();
                    });
                    _precacheNeighbors(pages, i);
                  },
                  itemBuilder: (context, i) => _PageCanvas(
                    page: pages[i],
                    drawMode: _drawMode,
                    showStrokes: _showStrokes,
                    eraser: _eraser,
                    penColor: _penColor,
                    penWidth: _penWidth,
                    onStrokeEnd: (s) => _onStrokeEnd(pages[i], s),
                    onEraseStart: () => _onEraseStart(pages[i]),
                    onEraseEnd: () => _onEraseEnd(pages[i]),
                    onTapZone: (fx) => _onTapZone(fx, pages.length),
                  ),
                ),
              ),
        bottomNavigationBar:
            pages.isEmpty || !showChrome ? null : _buildToolbar(pages[_index]),
      ),
    );
  }

  void _precacheNeighbors(List<MusicPage> pages, int index) {
    for (final d in const <int>[-1, 1]) {
      final i = index + d;
      if (i < 0 || i >= pages.length) continue;
      precacheImage(FileImage(File(pages[i].imagePath)), context);
    }
  }

  Widget _buildToolbar(MusicPage page) {
    final theme = Theme.of(context);
    if (!_drawMode) {
      return SafeArea(
        child: Container(
          color: Colors.black87,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: <Widget>[
              FilledButton.icon(
                onPressed: () => setState(() => _drawMode = true),
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('手書き'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const Spacer(),
              Text(
                'スワイプでページ送り',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              const Spacer(),
              const SizedBox(width: 8),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      child: Container(
        color: Colors.black87,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: '閲覧に戻る',
                icon: const Icon(Icons.check, color: Colors.white),
                onPressed: () => setState(() {
                  _drawMode = false;
                  _eraser = false;
                }),
              ),
              const _ToolbarDivider(),
              // ペンの色
              for (final c in _colors)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() {
                      _penColor = c;
                      _eraser = false;
                    }),
                    child: Container(
                      width: _penColor == c ? 34 : 28,
                      height: _penColor == c ? 34 : 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: _penColor == c
                            ? Border.all(color: Colors.white, width: 2)
                            : null,
                      ),
                      child: Icon(
                        Icons.edit,
                        size: 16,
                        color: Color(c),
                      ),
                    ),
                  ),
                ),
              const _ToolbarDivider(),
              // 線幅 (自作チップ: 黒背景でもラベルを確実に見せる)
              for (final w in _widths)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: GestureDetector(
                    onTap: () => setState(() {
                      _penWidth = w.$2;
                      _eraser = false;
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: _penWidth == w.$2
                            ? theme.colorScheme.primary
                            : Colors.white10,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _penWidth == w.$2
                              ? Colors.white
                              : Colors.white38,
                          width: 1.4,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Container(
                            width: w.$2 * 480,
                            height: w.$2 * 480,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            w.$1,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              const _ToolbarDivider(),
              GestureDetector(
                onTap: () => setState(() => _eraser = !_eraser),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: _eraser ? theme.colorScheme.primary : Colors.white10,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _eraser ? Colors.white : Colors.white38,
                      width: 1.4,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.cleaning_services,
                        size: 18,
                        color: _eraser ? Colors.white : Colors.white70,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '消しゴム',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _eraser ? Colors.white : Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: 'ひとつ戻す',
                icon: const Icon(Icons.undo, color: Colors.white),
                onPressed: () => _undo(page),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// 描画ツールバー用の固定高ディバイダー。
/// (VerticalDivider は親の高さ制約を無限に膨らませるため使用しない)
class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: Colors.white24,
    );
  }
}

/// 1 ページ分の表示 + 手書き入力。
class _PageCanvas extends StatefulWidget {
  const _PageCanvas({
    required this.page,
    required this.drawMode,
    required this.showStrokes,
    required this.eraser,
    required this.penColor,
    required this.penWidth,
    required this.onStrokeEnd,
    required this.onEraseStart,
    required this.onEraseEnd,
    required this.onTapZone,
  });

  /// 閲覧中のタップ位置 (ページ領域の横位置 0..1)。手書き中・拡大中は呼ばない。
  final ValueChanged<double> onTapZone;

  final MusicPage page;
  final bool drawMode;
  final bool showStrokes;
  final bool eraser;
  final int penColor;
  final double penWidth;
  final ValueChanged<Stroke> onStrokeEnd;
  final VoidCallback onEraseStart;
  final VoidCallback onEraseEnd;

  @override
  State<_PageCanvas> createState() => _PageCanvasState();
}

class _PageCanvasState extends State<_PageCanvas> {
  final TransformationController _transform = TransformationController();
  Stroke? _current;

  /// ズーム中のみ InteractiveViewer がパンを吸い、
  /// 等倍のときは横スワイプを PageView (ページ送り) に渡す。
  bool _zoomed = false;

  static const double _eraserRadius = 0.02; // ページ幅比

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
  }

  void _onTransformChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) {
      setState(() => _zoomed = zoomed);
    }
  }

  @override
  void didUpdateWidget(covariant _PageCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 手書きモードに入ったらズーム/ pan をリセットして座標系を揃える
    if (widget.drawMode && !oldWidget.drawMode) {
      _transform.value = Matrix4.identity();
      _current = null;
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Offset _normalize(Offset local, Rect rect) => Offset(
        ((local.dx - rect.left) / rect.width).clamp(0.0, 1.0),
        ((local.dy - rect.top) / rect.height).clamp(0.0, 1.0),
      );

  void _onPanStart(DragStartDetails d, Rect rect, MusicPage page) {
    if (!rect.contains(d.localPosition)) return;
    if (widget.eraser) {
      widget.onEraseStart();
      _eraseAt(_normalize(d.localPosition, rect), page);
      return;
    }
    final p = _normalize(d.localPosition, rect);
    setState(() {
      _current = Stroke(
        color: widget.penColor,
        width: widget.penWidth,
        points: <Offset>[p],
      );
    });
  }

  void _onPanUpdate(DragUpdateDetails d, Rect rect, MusicPage page) {
    if (widget.eraser) {
      _eraseAt(_normalize(d.localPosition, rect), page);
      return;
    }
    final current = _current;
    if (current == null) return;
    setState(() {
      current.points.add(_normalize(d.localPosition, rect));
    });
  }

  void _onPanEnd(DragEndDetails d, MusicPage page) {
    final current = _current;
    if (widget.eraser) {
      widget.onEraseEnd();
      return;
    }
    if (current != null) {
      if (current.points.length == 1) {
        // 点だけでも描けるように同じ点を複製
        current.points.add(current.points.first);
      }
      widget.onStrokeEnd(current);
    }
    setState(() => _current = null);
  }

  /// 部分消しゴム: 触れたストロークは消去半径で切断し、残り区間を保持する。
  void _eraseAt(Offset normalized, MusicPage page) {
    var changed = false;
    final next = <Stroke>[];
    for (final s in page.strokes) {
      if (!StrokeLayerPainter.hitsNormalized(s, normalized, _eraserRadius)) {
        next.add(s);
        continue;
      }
      changed = true;
      next.addAll(StrokeLayerPainter.splitStroke(s, normalized, _eraserRadius));
    }
    if (changed) {
      page.strokes = next;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final aspect = page.width > 0 && page.height > 0
        ? page.width / page.height
        : 1 / 1.414; // A4 縦フォールバック

    final image = Image.file(
      File(page.imagePath),
      fit: BoxFit.contain,
      cacheWidth: 2000,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white24, size: 64),
      ),
    );

    return InteractiveViewer(
      transformationController: _transform,
      panEnabled: !widget.drawMode && _zoomed,
      scaleEnabled: !widget.drawMode,
      maxScale: 5,
      minScale: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final rect = containRect(constraints.biggest, aspect);
          final strokesVisible = widget.showStrokes &&
              (widget.drawMode || page.strokes.isNotEmpty);
          return GestureDetector(
            // 拡大中はタップでページを送らない (パンの操作と紛れるため)
            onTapUp: !widget.drawMode && !_zoomed
                ? (d) => widget.onTapZone(d.localPosition.dx / constraints.maxWidth)
                : null,
            onDoubleTap: !widget.drawMode
                ? () {
                    // ダブルタップで等倍に戻す
                    if (_zoomed) {
                      _transform.value = Matrix4.identity();
                    }
                  }
                : null,
            onPanStart: widget.drawMode
                ? (d) => _onPanStart(d, rect, page)
                : null,
            onPanUpdate: widget.drawMode
                ? (d) => _onPanUpdate(d, rect, page)
                : null,
            onPanEnd:
                widget.drawMode ? (d) => _onPanEnd(d, page) : null,
            behavior: HitTestBehavior.opaque,
            child: SizedBox.expand(
              child: Stack(
                children: <Widget>[
                  Positioned.fromRect(rect: rect, child: image),
                  if (strokesVisible)
                    Positioned.fromRect(
                      rect: rect,
                      child: IgnorePointer(
                        child: CustomPaint(
                          size: rect.size,
                          painter: StrokeLayerPainter(
                            strokes: page.strokes,
                            rect: Offset.zero & rect.size,
                            current: _current,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// ビューアのタップ領域。
enum TapZone { previous, center, next }

/// 横位置 (0..1) をタップ領域に分ける。楽譜は左から右へ読むので右が次のページ。
TapZone tapZoneOf(double fx) {
  if (fx < 1 / 3) return TapZone.previous;
  if (fx > 2 / 3) return TapZone.next;
  return TapZone.center;
}
