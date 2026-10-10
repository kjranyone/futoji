import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';

import '../models/music_document.dart';
import '../models/music_page.dart';
import '../models/stroke.dart';
import 'db_service.dart';
import 'storage.dart';

/// 全教材のバックアップ (zip) の書き出しと復元。
///
/// zip の中身:
///   manifest.json   形式名・版・件数・作成日時
///   data.json       教材とページのメタデータ (手書きメモ・タグ・ページメモを含む)
///   `images/<pageId>.webp`, `thumbs/<pageId>.webp`
///
/// 画像の絶対パスは端末ごとに変わるので保存せず、復元時に AppPaths から作り直す。
/// 復元は「同じ教材 (id) は丸ごと置き換え、それ以外の手元の教材はそのまま」のマージ。
class BackupService {
  BackupService._();

  static const String formatName = 'futoji-backup';
  static const int formatVersion = 1;
  static const String filePrefix = 'futoji_backup_';

  /// zip 内で受け付けるページ画像の名前 (zip slip 対策で id の文字種を限定)。
  static final RegExp _pageFile = RegExp(r'^(images|thumbs)/([A-Za-z0-9_-]+)\.webp$');

  /// 書き出す前の見積もり。画像は無圧縮で格納するので、zip のサイズは
  /// 画像ファイルの合計 + メタデータ・zip ヘッダ (数 KB) とほぼ同じになる。
  static BackupEstimate estimate() {
    var pages = 0;
    var missing = 0;
    var bytes = 0;
    for (final p in DbService.pages.values) {
      final image = _existing(p.imagePath, AppPaths.imagePathFor(p.id));
      if (image == null) {
        missing++;
        continue;
      }
      pages++;
      bytes += File(image).lengthSync();
      final thumb = _existing(p.thumbPath, AppPaths.thumbPathFor(p.id));
      if (thumb != null) bytes += File(thumb).lengthSync();
      // ページごとのメタデータ (手書きを含む JSON) と zip のエントリヘッダの概算
      bytes += 512 + p.strokes.fold<int>(0, (n, s) => n + 16 * s.points.length);
    }
    return BackupEstimate(
      documentCount: DbService.documents.length,
      pageCount: pages,
      bytes: bytes + 4096,
      missingImages: missing,
    );
  }

  /// 全教材を zip に書き出す。[outDir] 省略時は一時ディレクトリ
  /// (前回の書き出しファイルは消す)。
  static Future<BackupExportResult> export({Directory? outDir}) async {
    final docs = DbService.documents.values.toList(growable: false);
    final pages = DbService.pages.values.toList(growable: false);
    final files = <List<String>>[];
    final exportedPages = <MusicPage>[];
    var missing = 0;
    for (final p in pages) {
      final image = _existing(p.imagePath, AppPaths.imagePathFor(p.id));
      if (image == null) {
        missing++;
        continue;
      }
      exportedPages.add(p);
      files.add(<String>[image, 'images/${p.id}.webp']);
      final thumb = _existing(p.thumbPath, AppPaths.thumbPathFor(p.id));
      if (thumb != null) files.add(<String>[thumb, 'thumbs/${p.id}.webp']);
    }
    final now = DateTime.now();
    final manifest = jsonEncode(<String, Object>{
      'format': formatName,
      'version': formatVersion,
      'createdAt': now.millisecondsSinceEpoch,
      'documents': docs.length,
      'pages': exportedPages.length,
    });
    final data = jsonEncode(<String, Object>{
      'documents': <Map<String, Object?>>[for (final d in docs) _docToMap(d)],
      'pages': <Map<String, Object?>>[for (final p in exportedPages) _pageToMap(p)],
    });

    final dir = outDir ?? await getTemporaryDirectory();
    if (outDir == null) await _deleteOldExports(dir);
    final stamp = '${now.year}${_two(now.month)}${_two(now.day)}_'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    final path = '${dir.path}${Platform.pathSeparator}$filePrefix$stamp.zip';
    await _runWriteZip(path, manifest, data, files);
    return BackupExportResult(
      file: File(path),
      documentCount: docs.length,
      pageCount: exportedPages.length,
      missingImages: missing,
    );
  }

  /// zip から復元する。形式が違う・壊れている場合は [FormatException]
  /// (手元のデータは変更しない)。
  static Future<BackupRestoreResult> restore(String zipPath) async {
    final tmp = await getTemporaryDirectory();
    final staging = await Directory(
            '${tmp.path}${Platform.pathSeparator}restore_${DateTime.now().microsecondsSinceEpoch}')
        .create(recursive: true);
    try {
      final texts = await _runExtractZip(zipPath, staging.path);
      final manifest = _decodeObject(texts['manifest'], 'manifest.json');
      if (manifest['format'] != formatName) {
        throw const FormatException('Futoji のバックアップではありません');
      }
      final version = manifest['version'];
      if (version is! int || version > formatVersion) {
        throw const FormatException('新しい版のアプリで作られたバックアップです。アプリを更新してください');
      }
      final data = _decodeObject(texts['data'], 'data.json');
      final docs = <MusicDocument>[
        for (final m in (data['documents'] as List<dynamic>? ?? const <dynamic>[]))
          _docFromMap(m as Map<String, dynamic>),
      ];
      final pagesByDoc = <String, List<MusicPage>>{};
      var skipped = 0;
      for (final m in (data['pages'] as List<dynamic>? ?? const <dynamic>[])) {
        final page = _pageFromMap(m as Map<String, dynamic>);
        if (!_pageFile.hasMatch('images/${page.id}.webp') ||
            !File(_stagedPath(staging.path, 'images', page.id)).existsSync()) {
          skipped++;
          continue;
        }
        (pagesByDoc[page.documentId] ??= <MusicPage>[]).add(page);
      }

      var restoredDocs = 0;
      var restoredPages = 0;
      for (final doc in docs) {
        final pages = pagesByDoc[doc.id];
        if (pages == null || pages.isEmpty) continue;
        await _replaceDocument(doc, pages, staging.path);
        restoredDocs++;
        restoredPages += pages.length;
      }
      return BackupRestoreResult(
        documentCount: restoredDocs,
        pageCount: restoredPages,
        skippedPages: skipped,
      );
    } finally {
      try {
        await staging.delete(recursive: true);
      } catch (_) {
        // 一時ファイルの掃除に失敗しても復元結果には影響しない
      }
    }
  }

  /// 手元の同じ id の教材を消して、バックアップの内容で置き換える。
  static Future<void> _replaceDocument(
      MusicDocument doc, List<MusicPage> pages, String staging) async {
    final old = DbService.pages.values
        .where((p) => p.documentId == doc.id)
        .toList(growable: false);
    for (final p in old) {
      await AppPaths.deletePageFiles(p.id);
    }
    await DbService.pages.deleteAll(old.map((p) => p.id));

    pages.sort((a, b) => a.index.compareTo(b.index));
    for (int i = 0; i < pages.length; i++) {
      final p = pages[i];
      final image = AppPaths.imagePathFor(p.id);
      final thumb = AppPaths.thumbPathFor(p.id);
      await _moveFile(_stagedPath(staging, 'images', p.id), image);
      final stagedThumb = _stagedPath(staging, 'thumbs', p.id);
      if (File(stagedThumb).existsSync()) {
        await _moveFile(stagedThumb, thumb);
      } else {
        // サムネイルが無いバックアップでも一覧に出せるよう本文画像で代用する
        await File(image).copy(thumb);
      }
      p
        ..index = i
        ..imagePath = image
        ..thumbPath = thumb;
      await DbService.pages.put(p.id, p);
    }
    doc
      ..pageCount = pages.length
      ..coverThumbPath = pages.first.thumbPath;
    await DbService.documents.put(doc.id, doc);
  }

  // ------------------------------------------------------------ isolate 側

  // Isolate.run のクロージャは囲む関数の変数ごと送られるため、引数だけを持つ関数で包む
  // (README「Flutter の落とし穴メモ」)。
  static Future<void> _runWriteZip(
          String path, String manifest, String data, List<List<String>> files) =>
      Isolate.run(() => _writeZip(path, manifest, data, files));

  static Future<Map<String, String>> _runExtractZip(String zipPath, String staging) =>
      Isolate.run(() => _extractZip(zipPath, staging));

  static Future<void> _writeZip(
      String path, String manifest, String data, List<List<String>> files) async {
    final encoder = ZipFileEncoder()..create(path);
    try {
      encoder.addArchiveFile(ArchiveFile.string('manifest.json', manifest));
      encoder.addArchiveFile(ArchiveFile.string('data.json', data));
      // WebP は圧縮済みなので無圧縮で格納する (時間がかかるだけで小さくならない)
      // (archive 4.x は addFile の level では無圧縮にならず、ArchiveFile.compression で指定する)
      for (final f in files) {
        final input = InputFileStream(f[0]);
        try {
          encoder.addArchiveFile(ArchiveFile.stream(f[1], input)
            ..compression = CompressionType.none);
        } finally {
          await input.close();
        }
      }
    } finally {
      await encoder.close();
    }
  }

  /// manifest.json / data.json の文字列を返し、ページ画像を [staging] に展開する。
  /// 想定外の名前のエントリは無視する (パス・トラバーサル対策を兼ねる)。
  static Map<String, String> _extractZip(String zipPath, String staging) {
    final input = InputFileStream(zipPath);
    try {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } catch (_) {
        throw const FormatException('zip ファイルを読み込めませんでした');
      }
      final texts = <String, String>{};
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final name = entry.name.replaceAll('\\', '/');
        if (name == 'manifest.json' || name == 'data.json') {
          texts[name.substring(0, name.length - 5)] =
              utf8.decode(entry.readBytes() ?? const <int>[]);
          continue;
        }
        final m = _pageFile.firstMatch(name);
        if (m == null) continue;
        final out = OutputFileStream(_stagedPath(staging, m.group(1)!, m.group(2)!));
        try {
          entry.writeContent(out);
        } finally {
          out.closeSync();
        }
      }
      return texts;
    } finally {
      input.closeSync();
    }
  }

  // ---------------------------------------------------------------- 変換

  static Map<String, Object?> _docToMap(MusicDocument d) => <String, Object?>{
        'id': d.id,
        'title': d.title,
        'createdAt': d.createdAt,
        'updatedAt': d.updatedAt,
        'tags': d.tags,
      };

  static MusicDocument _docFromMap(Map<String, dynamic> m) => MusicDocument(
        id: m['id'] as String,
        title: m['title'] as String? ?? '無題の教材',
        createdAt: (m['createdAt'] as num?)?.toInt() ?? 0,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        tags: <String>[
          for (final t in (m['tags'] as List<dynamic>? ?? const <dynamic>[])) t as String,
        ],
      );

  static Map<String, Object?> _pageToMap(MusicPage p) => <String, Object?>{
        'id': p.id,
        'documentId': p.documentId,
        'index': p.index,
        'width': p.width,
        'height': p.height,
        'updatedAt': p.updatedAt,
        'note': p.note,
        'strokes': <Map<String, dynamic>>[for (final s in p.strokes) s.toMap()],
      };

  static MusicPage _pageFromMap(Map<String, dynamic> m) => MusicPage(
        id: m['id'] as String,
        documentId: m['documentId'] as String,
        index: (m['index'] as num?)?.toInt() ?? 0,
        imagePath: '',
        thumbPath: '',
        width: (m['width'] as num?)?.toInt() ?? 0,
        height: (m['height'] as num?)?.toInt() ?? 0,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
        note: m['note'] as String? ?? '',
        strokes: <Stroke>[
          for (final s in (m['strokes'] as List<dynamic>? ?? const <dynamic>[]))
            Stroke.fromMap(s as Map<String, dynamic>),
        ],
      );

  // ------------------------------------------------------------ 補助

  static Map<String, dynamic> _decodeObject(String? text, String name) {
    if (text == null) throw FormatException('$name がありません');
    final v = jsonDecode(text);
    if (v is! Map<String, dynamic>) throw FormatException('$name の形式が不正です');
    return v;
  }

  static String _stagedPath(String staging, String kind, String id) =>
      '$staging${Platform.pathSeparator}$kind-$id.webp';

  static String? _existing(String primary, String fallback) {
    if (primary.isNotEmpty && File(primary).existsSync()) return primary;
    if (File(fallback).existsSync()) return fallback;
    return null;
  }

  static Future<void> _moveFile(String from, String to) async {
    try {
      await File(from).rename(to);
    } on FileSystemException {
      // 別ボリュームなど rename できない場合はコピー
      await File(from).copy(to);
      await File(from).delete();
    }
  }

  static Future<void> _deleteOldExports(Directory dir) async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      final name = e.uri.pathSegments.isEmpty ? '' : e.uri.pathSegments.last;
      if (e is File && name.startsWith(filePrefix) && name.endsWith('.zip')) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

class BackupEstimate {
  BackupEstimate({
    required this.documentCount,
    required this.pageCount,
    required this.bytes,
    required this.missingImages,
  });

  final int documentCount;
  final int pageCount;

  /// zip の予想サイズ (バイト)。
  final int bytes;
  final int missingImages;
}

/// 人が読むサイズ表記 (例: 980 KB / 12.3 MB / 1.20 GB)。
String formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / kb).ceil()} KB';
}

class BackupExportResult {
  BackupExportResult({
    required this.file,
    required this.documentCount,
    required this.pageCount,
    required this.missingImages,
  });

  final File file;
  final int documentCount;
  final int pageCount;

  /// 画像ファイルが見つからず書き出せなかったページ数。
  final int missingImages;
}

class BackupRestoreResult {
  BackupRestoreResult({
    required this.documentCount,
    required this.pageCount,
    required this.skippedPages,
  });

  final int documentCount;
  final int pageCount;

  /// 画像が無い・id が不正で復元できなかったページ数。
  final int skippedPages;
}
