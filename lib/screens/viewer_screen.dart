import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart' show DeviceGestureSettings, DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:provider/provider.dart';

import '../models/music_document.dart';
import '../models/music_page.dart';
import '../models/stroke.dart';
import '../screens/camera_screen.dart';
import '../state/app_state.dart';
import '../widgets/corner_overlay.dart';
import '../widgets/dialogs.dart';
import '../widgets/edge_swipe_back.dart';
import '../widgets/image_fade_in.dart';
import '../widgets/pdf_actions.dart';
import '../widgets/snappy_page_physics.dart';
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

  /// バーの出し入れと、それに合わせてページが広がる/縮むアニメーションの長さ。
  static const Duration chromeDuration = Duration(milliseconds: 200);

  /// 中央タップで数秒だけ出す操作のヒント。
  bool _showHints = false;
  Timer? _hintTimer;
  static const Duration hintDuration = Duration(milliseconds: 2500);

  void _flashHints() {
    _hintTimer?.cancel();
    setState(() => _showHints = true);
    _hintTimer = Timer(hintDuration, () {
      if (mounted) setState(() => _showHints = false);
    });
  }

  /// ページの端で出す短い知らせ (「最後のページです」など)。
  /// SnackBar だとページの下を 2 秒ふさぐので、小さな吹き出しを一瞬出すだけにする。
  String? _toastText;
  bool _toastVisible = false;
  Timer? _toastTimer;
  static const Duration toastDuration = Duration(milliseconds: 1400);

  void _flashToast(String text) {
    _toastTimer?.cancel();
    setState(() {
      _toastText = text;
      _toastVisible = true;
    });
    _toastTimer = Timer(toastDuration, () {
      if (mounted) setState(() => _toastVisible = false);
    });
  }

  /// ページの端に当たったとき: 軽く振動して知らせる。
  void _bump(String text) {
    HapticFeedback.lightImpact();
    _flashToast(text);
  }

  bool _drawMode = false;
  bool _showStrokes = true;
  bool _eraser = false;
  int _penColor = 0xFFE53935;

  /// 既定は「中」(チップのどれかが選ばれて見えるよう、候補の値に揃える)。
  double _penWidth = 0.007;

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
    _hintTimer?.cancel();
    _toastTimer?.cancel();
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

  Future<void> _rotateCurrent(List<MusicPage> pages, {required bool clockwise}) async {
    if (pages.isEmpty) return;
    final page = pages[_index.clamp(0, pages.length - 1)];
    try {
      await context.read<AppState>().rotatePage(page, clockwise: clockwise);
    } catch (e) {
      debugPrint('rotatePage: $e');
      if (mounted) showSnackBar(context, 'ページを回転できませんでした');
      return;
    }
    // 回す前の向きの手書きは戻せないので履歴を捨てる
    if (mounted) setState(_undoStack.clear);
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
    if (_undoStack.isEmpty) {
      _bump('戻せる操作はありません');
      return;
    }
    page.strokes = _undoStack.removeLast();
    context.read<AppState>().saveStrokes(page);
    setState(() {});
  }

  void _setDrawMode(bool on) {
    setState(() {
      _drawMode = on;
      _eraser = false;
    });
  }

  /// 漫画ビューアのようなタップ操作: 左 1/3 で前、右 1/3 で次のページ、中央でバーの表示切替。
  void _onTapZone(double fx, int total) {
    switch (tapZoneOf(fx)) {
      case TapZone.previous:
        if (_index <= 0) {
          _bump('最初のページです');
          return;
        }
        _pageController.previousPage(
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      case TapZone.next:
        if (_index >= total - 1) {
          _bump('最後のページです');
          return;
        }
        _pageController.nextPage(
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      case TapZone.center:
        setState(() => _chromeHidden = !_chromeHidden);
        _flashHints();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final pages = app.cachedPages(widget.document.id) ?? const <MusicPage>[];
    final showChrome = !_chromeHidden || _drawMode;
    // 上のバーの高さ (ステータスバー込み)。バーを出している間はページをこの下に収め、
    // 隠すとこの分だけ広がる
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    // 手書き中は端からのスワイプで戻らない (端の近くに書けるように)。
    // 戻る操作 (ボタン・システムの戻る) は「閲覧に戻る」として扱う。
    return PopScope(
      canPop: !_drawMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_drawMode) return;
        _setDrawMode(false);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        // バーはページの上に重ねて滑り出し入れする (バーを消した瞬間にページが
        // 飛ぶのではなく、ページがバーの分だけ滑らかに広がる)
        extendBodyBehindAppBar: true,
        appBar: _SlidingBar(
          visible: showChrome,
          child: AppBar(
            backgroundColor: Colors.black87,
            foregroundColor: Colors.white,
            title: Text(
              pages.isEmpty ? '-' : '${_index + 1} / ${pages.length}',
              style: const TextStyle(fontSize: 15),
            ),
            actions: <Widget>[
              // 閲覧中は下のバーを出さず、手書きの入口はここに置く (ページを広く表示する)
              if (!_drawMode)
                TextButton.icon(
                  onPressed: pages.isEmpty ? null : () => _setDrawMode(true),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  label: const Text('手書き'),
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                ),
              IconButton(
                tooltip: _showStrokes ? 'メモを隠す' : 'メモを表示',
                icon: Icon(_showStrokes ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _showStrokes = !_showStrokes),
              ),
              IconButton(
                tooltip: 'さらにスキャン',
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
                  } else if (v == 'rotate_right' || v == 'rotate_left') {
                    _rotateCurrent(pages, clockwise: v == 'rotate_right');
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
                  PopupMenuItem<String>(
                    value: 'rotate_right',
                    enabled: pages.isNotEmpty,
                    child: const ListTile(
                      leading: Icon(Icons.rotate_right),
                      title: Text('右に回転'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'rotate_left',
                    enabled: pages.isNotEmpty,
                    child: const ListTile(
                      leading: Icon(Icons.rotate_left),
                      title: Text('左に回転'),
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
        ),
        body: _withOverlays(
          bottomInset: bottomInset,
          child: pages.isEmpty
              ? const Center(
                  child: Text('ページがありません', style: TextStyle(color: Colors.white54)))
              : AnimatedPadding(
                  duration: chromeDuration,
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.only(top: showChrome ? topInset : 0),
                  child: EdgeSwipeBack(
                    label: '一覧に戻る',
                    enabled: !_drawMode,
                    // ページめくりの効き始めを早くする: 動き出しの閾値を 18 → 12px にし
                    // (拡大の判定より先にページめくりが取る)、触れた位置から指に追従させる
                    child: MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                          gestureSettings: const DeviceGestureSettings(touchSlop: 12)),
                      child: PageView.builder(
                        controller: _pageController,
                        dragStartBehavior: DragStartBehavior.down,
                        // 吸着は SnappyPageScrollPhysics が行う (true だと標準の吸着が上に被さる)
                        pageSnapping: false,
                        physics: _drawMode
                            ? const NeverScrollableScrollPhysics()
                            : const SnappyPageScrollPhysics(),
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
                  ),
                ),
        ),
        // 下のバーは手書き中のツール (ペン・消しゴム) だけ。閲覧中はページを広く使う。
        // 出し入れは高さをアニメーションし、ページがそれに合わせて縮む/広がる
        bottomNavigationBar: AnimatedSize(
          duration: chromeDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: pages.isEmpty || !_drawMode
              ? const SizedBox(width: double.infinity)
              : _buildToolbar(pages[_index]),
        ),
      ),
    );
  }

  /// ページの上に操作のヒントと短い知らせを重ねる (タッチは下へ通すので、出ている間も操作できる)。
  Widget _withOverlays({required Widget child, required double bottomInset}) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          child,
          IgnorePointer(
            child: AnimatedOpacity(
              key: const ValueKey<String>('viewer-hints'),
              opacity: _showHints && !_drawMode ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: const _ViewerHints(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset + 28,
            child: IgnorePointer(
              child: AnimatedOpacity(
                key: const ValueKey<String>('viewer-toast'),
                opacity: _toastVisible ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Text(
                      _toastText ?? '',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );

  void _precacheNeighbors(List<MusicPage> pages, int index) {
    for (final d in const <int>[-1, 1]) {
      final i = index + d;
      if (i < 0 || i >= pages.length) continue;
      precacheImage(FileImage(File(pages[i].imagePath)), context);
    }
  }

  Widget _buildToolbar(MusicPage page) {
    // Material にしておく (Container だとその色がインクの上に乗り、押した反応が見えない)
    return Material(
      color: Colors.black87,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: '閲覧に戻る',
                  icon: const Icon(Icons.check, color: Colors.white),
                  onPressed: () => _setDrawMode(false),
                ),
                const _ToolbarDivider(),
                // ペンの色
                for (final c in _colors)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _penColor = c;
                          _eraser = false;
                        });
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        curve: Curves.easeOut,
                        width: _penColor == c && !_eraser ? 34 : 28,
                        height: _penColor == c && !_eraser ? 34 : 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _penColor == c && !_eraser
                                ? Colors.white
                                : Colors.transparent,
                            width: 2,
                          ),
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
                  _ToolChip(
                    selected: _penWidth == w.$2 && !_eraser,
                    onTap: () => setState(() {
                      _penWidth = w.$2;
                      _eraser = false;
                    }),
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
                const _ToolbarDivider(),
                _ToolChip(
                  selected: _eraser,
                  onTap: () => setState(() => _eraser = !_eraser),
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
      ),
    );
  }
}

/// ビューアの上のバー。隠すときは上へ滑り出て、ページの上には何も残さない
/// (隠れている間はタッチも通さない)。
class _SlidingBar extends StatelessWidget implements PreferredSizeWidget {
  const _SlidingBar({required this.visible, required this.child});

  final bool visible;
  final PreferredSizeWidget child;

  @override
  Size get preferredSize => child.preferredSize;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        key: const ValueKey<String>('viewer-chrome'),
        offset: visible ? Offset.zero : const Offset(0, -1),
        duration: _ViewerScreenState.chromeDuration,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: _ViewerScreenState.chromeDuration,
          curve: Curves.easeOut,
          child: child,
        ),
      ),
    );
  }
}

/// 手書きツールバーの選択チップ (線幅・消しゴム)。
/// 押すとインクが広がって軽く振動し、選択状態の色は滑らかに切り替わる。
class _ToolChip extends StatelessWidget {
  const _ToolChip({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: selected ? scheme.primary : Colors.white10,
        shape: StadiumBorder(
          side: BorderSide(
            color: selected ? Colors.white : Colors.white38,
            width: 1.4,
          ),
        ),
        animationDuration: const Duration(milliseconds: 150),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: child,
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

class _PageCanvasState extends State<_PageCanvas>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  Stroke? _current;

  /// ズーム中のみ InteractiveViewer がパンを吸い、
  /// 等倍のときは横スワイプを PageView (ページ送り) に渡す。
  bool _zoomed = false;

  /// ダブルタップで等倍に戻すときのアニメーション (ぱっと切り替わらずに縮む)。
  late final AnimationController _zoomController =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Matrix4>? _zoomAnimation;

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

  void _onZoomTick() {
    _transform.value = _zoomAnimation!.value;
  }

  /// 等倍へ滑らかに戻す。
  void _resetZoom() {
    _zoomAnimation?.removeListener(_onZoomTick);
    _zoomAnimation = Matrix4Tween(begin: _transform.value, end: Matrix4.identity())
        .animate(CurvedAnimation(parent: _zoomController, curve: Curves.easeOutCubic))
      ..addListener(_onZoomTick);
    _zoomController.forward(from: 0);
  }

  @override
  void didUpdateWidget(covariant _PageCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 手書きモードに入ったらズーム/ pan を戻して座標系を揃える
    if (widget.drawMode && !oldWidget.drawMode) {
      if (_zoomed) _resetZoom();
      _current = null;
    }
  }

  @override
  void dispose() {
    _zoomController.dispose();
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
      // 本文の読み込みが終わるまでは下のサムネイルが見えていて、終わるとふわっと差し替わる
      frameBuilder: fadeInImageFrame,
      errorBuilder: (_, _, _) => const Center(
        child: Icon(Icons.broken_image_outlined, color: Colors.white24, size: 64),
      ),
    );
    // 本文 (長辺 2400px) のデコードを待つ間の下敷き。小さいのですぐ出る
    final thumb = page.thumbPath.isEmpty
        ? null
        : Image.file(
            File(page.thumbPath),
            fit: BoxFit.fill,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          );

    return InteractiveViewer(
      transformationController: _transform,
      panEnabled: !widget.drawMode && _zoomed,
      scaleEnabled: !widget.drawMode,
      // 指で触れたら等倍へ戻すアニメーションは止め、指の操作を優先する
      onInteractionStart: (_) => _zoomController.stop(),
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
            // ダブルタップは「等倍に戻す」だけなので、拡大中にだけ受け付ける。
            // 等倍のときにも受け付けると、1 回のタップが 2 回目を待って 0.3 秒遅れる
            onDoubleTap: !widget.drawMode && _zoomed ? _resetZoom : null,
            // 手書きの線は指が触れた点から始める (動き出しを待った位置からだと始点がずれる)
            dragStartBehavior: DragStartBehavior.down,
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
                  // 画像は手書きの描き足しごとに描き直さない (線のレイヤーだけを更新する)
                  Positioned.fromRect(
                    rect: rect,
                    child: RepaintBoundary(
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          ?thumb,
                          image,
                        ],
                      ),
                    ),
                  ),
                  if (strokesVisible)
                    Positioned.fromRect(
                      rect: rect,
                      child: IgnorePointer(
                        child: CustomPaint(
                          size: rect.size,
                          willChange: _current != null,
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

/// 中央タップで出す操作のヒント: 左右と中央のタップ領域と、その他の操作。
class _ViewerHints extends StatelessWidget {
  const _ViewerHints();

  @override
  Widget build(BuildContext context) {
    const label = TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600);
    Widget zone(IconData icon, String text, {bool middle = false}) => Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: middle ? 0.30 : 0.45),
              border: middle
                  ? const Border.symmetric(
                      vertical: BorderSide(color: Colors.white38, width: 1))
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, color: Colors.white, size: 40),
                const SizedBox(height: 6),
                Text(text, style: label, textAlign: TextAlign.center),
                const SizedBox(height: 2),
                const Text('タップ', style: TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
        );
    return Column(
      children: <Widget>[
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              zone(Icons.chevron_left, '前のページ'),
              zone(Icons.menu, 'メニューの\n表示/非表示', middle: true),
              zone(Icons.chevron_right, '次のページ'),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          color: Colors.black.withValues(alpha: 0.7),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: const Text(
            'スワイプでもめくれます ・ 2 本指で拡大 ・ ダブルタップで元の大きさ ・ 左端からスワイプで一覧に戻る',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ],
    );
  }
}
