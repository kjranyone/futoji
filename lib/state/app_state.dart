import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/crop_result.dart';
import '../models/music_document.dart';
import '../models/music_page.dart';
import '../services/db_service.dart';
import '../services/ids.dart';
import '../services/image_pipeline.dart';
import '../services/storage.dart';

/// アプリ全体の状態 (教材・ページの CRUD)。
class AppState extends ChangeNotifier {
  final Map<String, List<MusicPage>> _pagesCache = <String, List<MusicPage>>{};

  /// 保存時に色数を自動減色するオプション (楽譜など無彩色寄りの資料で効く)。
  bool reduceColors = false;

  void setReduceColors(bool value) {
    if (reduceColors == value) return;
    reduceColors = value;
    notifyListeners();
  }

  static const String _aiSharpenKey = 'ai_sharpen';

  /// 撮影した紙面を AI でシャープ化してから保存するか (設定画面、端末に保存)。
  bool get aiSharpen =>
      DbService.settings.get(_aiSharpenKey, defaultValue: false) as bool;

  Future<void> setAiSharpen(bool value) async {
    await DbService.settings.put(_aiSharpenKey, value);
    notifyListeners();
  }

  static const String _dewarpKey = 'dewarp_staff';

  /// 五線を手がかりに紙面の曲がり (本のノド付近の反り) を補正して保存するか
  /// (設定画面とカメラ右上、端末に保存)。五線が見つからないページは補正しない。
  bool get dewarp => DbService.settings.get(_dewarpKey, defaultValue: true) as bool;

  Future<void> setDewarp(bool value) async {
    await DbService.settings.put(_dewarpKey, value);
    notifyListeners();
  }

  List<MusicDocument> _documents = <MusicDocument>[];

  /// 更新日の新しい順。
  List<MusicDocument> get documents => List<MusicDocument>.unmodifiable(_documents);

  // -------------------------------------------------------------- documents

  /// 0 ページの空教材を起動時に掃除する
  /// (カメラ起動中に強制終了/クラッシュした場合の残骸防止)。
  Future<void> cleanupEmptyDocuments() async {
    final empties = DbService.documents.values
        .where((d) => d.pageCount <= 0)
        .toList(growable: false);
    for (final d in empties) {
      await DbService.documents.delete(d.id);
      _pagesCache.remove(d.id);
    }
    if (empties.isNotEmpty) {
      await refreshDocuments();
    }
  }

  Future<void> refreshDocuments() async {
    final list = DbService.documents.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _documents = list;
    notifyListeners();
  }

  /// バックアップの復元などで DB を直接書き換えた後に、キャッシュを捨てて読み直す。
  Future<void> reloadAll() async {
    _pagesCache.clear();
    await refreshDocuments();
  }

  MusicDocument? documentById(String id) {
    for (final d in _documents) {
      if (d.id == id) return d;
    }
    return DbService.documents.get(id);
  }

  Future<MusicDocument> createDocument() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final doc = MusicDocument(
      id: newId(),
      title: '無題の教材',
      createdAt: now,
      updatedAt: now,
    );
    await DbService.documents.put(doc.id, doc);
    await refreshDocuments();
    return doc;
  }

  Future<void> renameDocument(MusicDocument doc, String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    doc.title = t;
    doc.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await DbService.documents.put(doc.id, doc);
    await refreshDocuments();
  }

  Future<void> deleteDocument(MusicDocument doc) async {
    final pages = await pagesOf(doc.id);
    for (final p in pages) {
      await AppPaths.deletePageFiles(p.id);
    }
    await DbService.pages.deleteAll(pages.map((p) => p.id));
    await DbService.documents.delete(doc.id);
    _pagesCache.remove(doc.id);
    await refreshDocuments();
  }

  // ----------------------------------------------------------------- pages

  /// キャッシュ済みなら即座に返す。未ロードなら読み込む。
  Future<List<MusicPage>> pagesOf(String documentId) async {
    final cached = _pagesCache[documentId];
    if (cached != null) return cached;
    return reloadPages(documentId);
  }

  Future<List<MusicPage>> reloadPages(String documentId) async {
    final list = DbService.pages.values
        .where((p) => p.documentId == documentId)
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    _pagesCache[documentId] = list;
    return list;
  }

  List<MusicPage>? cachedPages(String documentId) => _pagesCache[documentId];

  /// 撮影 1 枚を処理してページとして保存する。
  Future<MusicPage> addScannedPage({
    required MusicDocument document,
    required String rawPath,
    required CropResult crop,
  }) async {
    final pages = await pagesOf(document.id);
    final pageId = newId();
    final scan = await ImagePipeline.processAndSave(
      rawFile: File(rawPath),
      cornersNormalized: crop.corners,
      rotationDeg: crop.rotation,
      pageId: pageId,
      // ライブ検出の枠ならフレーム座標なので、本撮影画像への写像を任せる
      liveFrame: crop.frameWidth != null ? crop : null,
      reduceColors: reduceColors,
      aiSharpen: aiSharpen,
      dewarp: dewarp,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    final page = MusicPage(
      id: pageId,
      documentId: document.id,
      index: pages.length,
      imagePath: scan.imageFile.path,
      thumbPath: scan.thumbFile.path,
      width: scan.width,
      height: scan.height,
      updatedAt: now,
    );
    await DbService.pages.put(page.id, page);

    document.pageCount = pages.length + 1;
    document.updatedAt = now;
    document.coverThumbPath ??= scan.thumbFile.path;
    await DbService.documents.put(document.id, document);

    await reloadPages(document.id);
    await refreshDocuments();
    return page;
  }

  /// 並び替えモードの結果をまとめて保存する。[ordered] の順に index を 0..n-1 で振り直し、
  /// 表紙を新しい 1 ページ目にする。
  Future<void> reorderPages(MusicDocument document, List<MusicPage> ordered) async {
    for (int k = 0; k < ordered.length; k++) {
      final p = ordered[k];
      if (p.index != k) {
        p.index = k;
        await DbService.pages.put(p.id, p);
      }
    }
    if (ordered.isNotEmpty) document.coverThumbPath = ordered.first.thumbPath;
    document.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await DbService.documents.put(document.id, document);
    await reloadPages(document.id);
    await refreshDocuments();
  }

  /// ページを delta (-1 / +1) だけ前後に移動し、index を再採番する。
  Future<void> movePage(MusicPage page, int delta) async {
    final pages = await pagesOf(page.documentId);
    final i = pages.indexOf(page);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= pages.length) return;
    final tmp = pages[i].index;
    pages[i].index = pages[j].index;
    pages[j].index = tmp;
    await DbService.pages.put(pages[i].id, pages[i]);
    await DbService.pages.put(pages[j].id, pages[j]);
    // 念のため全ページの index を 0..n-1 に整列
    final list = await reloadPages(page.documentId);
    for (int k = 0; k < list.length; k++) {
      if (list[k].index != k) {
        list[k].index = k;
        await DbService.pages.put(list[k].id, list[k]);
      }
    }
    final sorted = await reloadPages(page.documentId);
    final doc = DbService.documents.get(page.documentId);
    if (doc != null) {
      // 1 ページ目が入れ替わったら表紙も追従させる
      if (sorted.isNotEmpty) doc.coverThumbPath = sorted.first.thumbPath;
      doc.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await DbService.documents.put(doc.id, doc);
    }
    await refreshDocuments();
  }

  /// 手書きメモの保存 (ページオブジェクトの strokes を書き換えてから呼ぶ)。
  Future<void> saveStrokes(MusicPage page) async {
    page.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await DbService.pages.put(page.id, page);
  }

  /// ページメモを保存する (Index 検索の対象)。
  Future<void> setPageNote(MusicPage page, String note) async {
    page.note = note.trim();
    await saveStrokes(page);
  }

  /// 教材タグを保存する (Index 検索の対象)。
  Future<void> setDocumentTags(MusicDocument doc, List<String> tags) async {
    doc.tags = tags
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    doc.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await DbService.documents.put(doc.id, doc);
    await refreshDocuments();
  }

  Future<void> deletePage(MusicPage page) async {
    await AppPaths.deletePageFiles(page.id);
    await DbService.pages.delete(page.id);
    final doc = DbService.documents.get(page.documentId);
    final remaining = await reloadPages(page.documentId);
    // 歯抜けになった index を詰める
    for (int i = 0; i < remaining.length; i++) {
      if (remaining[i].index != i) {
        remaining[i].index = i;
        await DbService.pages.put(remaining[i].id, remaining[i]);
      }
    }
    if (doc != null) {
      doc.pageCount = remaining.length;
      doc.updatedAt = DateTime.now().millisecondsSinceEpoch;
      if (remaining.isEmpty) {
        doc.coverThumbPath = null;
      } else {
        doc.coverThumbPath = remaining.first.thumbPath;
      }
      await DbService.documents.put(doc.id, doc);
    }
    await refreshDocuments();
  }
}
