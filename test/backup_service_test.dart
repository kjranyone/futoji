// バックアップ (zip) の書き出し → 復元を、実際の Hive と画像ファイルで検証する。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:futoji/models/adapters.dart';
import 'package:futoji/models/music_document.dart';
import 'package:futoji/models/music_page.dart';
import 'package:futoji/models/stroke.dart';
import 'package:futoji/services/backup_service.dart';
import 'package:futoji/services/db_service.dart';
import 'package:futoji/services/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/docs';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

void main() {
  late Directory root;
  late Directory out;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('futoji_backup_test');
    await Directory('${root.path}/tmp').create();
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    // AppPaths は late final なのでテスト全体で 1 回だけ初期化する
    await AppPaths.init();
    Hive.init('${root.path}/hive');
    Hive.registerAdapter(MusicDocumentAdapter());
    Hive.registerAdapter(MusicPageAdapter());
  });

  setUp(() async {
    await Hive.openBox<MusicDocument>('documents');
    await Hive.openBox<MusicPage>('pages');
    out = await Directory('${root.path}/out').create();
  });

  tearDown(() async {
    await DbService.documents.clear();
    await DbService.pages.clear();
    await Hive.close();
    for (final dir in <String>[AppPaths.imagesDir, AppPaths.thumbsDir]) {
      for (final f in Directory(dir).listSync()) {
        f.deleteSync();
      }
    }
    await out.delete(recursive: true);
  });

  tearDownAll(() async {
    await root.delete(recursive: true);
  });

  Future<MusicPage> addPage(String docId, String pageId, int index,
      {String note = '', List<Stroke>? strokes}) async {
    final image = File(AppPaths.imagePathFor(pageId))
      ..writeAsBytesSync(utf8.encode('image-$pageId'));
    final thumb = File(AppPaths.thumbPathFor(pageId))
      ..writeAsBytesSync(utf8.encode('thumb-$pageId'));
    final page = MusicPage(
      id: pageId,
      documentId: docId,
      index: index,
      imagePath: image.path,
      thumbPath: thumb.path,
      width: 800,
      height: 1100,
      updatedAt: 2,
      note: note,
      strokes: strokes,
    );
    await DbService.pages.put(pageId, page);
    return page;
  }

  Future<void> addDoc(String id, String title, int pages) async {
    for (int i = 0; i < pages; i++) {
      await addPage(id, '${id}p$i', i);
    }
    await DbService.documents.put(
        id,
        MusicDocument(
          id: id,
          title: title,
          createdAt: 1,
          updatedAt: 2,
          pageCount: pages,
          coverThumbPath: AppPaths.thumbPathFor('${id}p0'),
          tags: <String>['基礎'],
        ));
  }

  test('書き出し → 全消去 → 復元で教材・ページ・手書き・画像が戻る', () async {
    await addDoc('docA', 'バイエル', 0);
    await addPage('docA', 'docAp0', 0,
        note: 'ここで転調',
        strokes: <Stroke>[
          Stroke(color: 0xFFFF0000, width: 0.01, points: const <Offset>[
            Offset(0.1, 0.2),
            Offset(0.3, 0.4),
          ]),
        ]);
    await addPage('docA', 'docAp1', 1);
    DbService.documents.get('docA')!.pageCount = 2;
    await addDoc('docB', 'ツェルニー', 1);

    final result = await BackupService.export(outDir: out);
    expect(result.documentCount, 2);
    expect(result.pageCount, 3);
    expect(result.missingImages, 0);
    // 画像 (WebP) は無圧縮で格納する
    final zipStream = InputFileStream(result.file.path);
    try {
      final zip = ZipDecoder().decodeStream(zipStream);
      expect(zip.findFile('images/docAp0.webp')!.compression, CompressionType.none);
    } finally {
      zipStream.closeSync();
    }

    // 端末のデータをすべて失った状態にする
    await DbService.documents.clear();
    await DbService.pages.clear();
    for (final dir in <String>[AppPaths.imagesDir, AppPaths.thumbsDir]) {
      for (final f in Directory(dir).listSync()) {
        f.deleteSync();
      }
    }

    final restored = await BackupService.restore(result.file.path);
    expect(restored.documentCount, 2);
    expect(restored.pageCount, 3);
    expect(restored.skippedPages, 0);

    final doc = DbService.documents.get('docA')!;
    expect(doc.title, 'バイエル');
    expect(doc.tags, <String>['基礎']);
    expect(doc.pageCount, 2);
    expect(doc.coverThumbPath, AppPaths.thumbPathFor('docAp0'));
    final page = DbService.pages.get('docAp0')!;
    expect(page.note, 'ここで転調');
    expect(page.strokes.single.points.last, const Offset(0.3, 0.4));
    expect(page.imagePath, AppPaths.imagePathFor('docAp0'));
    expect(File(page.imagePath).readAsStringSync(), 'image-docAp0');
    expect(File(page.thumbPath).readAsStringSync(), 'thumb-docAp0');
  });

  test('復元は同じ教材だけ置き換え、手元にしかない教材は残す', () async {
    await addDoc('docA', '元のタイトル', 2);
    final backup = await BackupService.export(outDir: out);

    // バックアップ後に docA を 1 ページに減らして改名し、新しい docC を作る
    await DbService.pages.delete('docAp1');
    File(AppPaths.imagePathFor('docAp1')).deleteSync();
    DbService.documents.get('docA')!
      ..title = '改名後'
      ..pageCount = 1;
    await addDoc('docC', '手元だけの教材', 1);

    await BackupService.restore(backup.file.path);

    expect(DbService.documents.get('docA')!.title, '元のタイトル');
    expect(DbService.pages.values.where((p) => p.documentId == 'docA').length, 2);
    expect(DbService.documents.get('docC')!.title, '手元だけの教材');
    expect(File(AppPaths.imagePathFor('docCp0')).existsSync(), isTrue);
  });

  test('見積もりサイズは実際の zip とほぼ一致する', () async {
    // 実際の画像に近い大きさ (本文 300 KB・サムネイル 20 KB) の非圧縮性データで 10 ページ
    final rnd = List<int>.generate(320 * 1024, (i) => (i * 2654435761) >> 7 & 0xFF);
    for (int i = 0; i < 10; i++) {
      final page = await addPage('docA', 'docAp$i', i);
      File(page.imagePath).writeAsBytesSync(rnd.sublist(0, 300 * 1024));
      File(page.thumbPath).writeAsBytesSync(rnd.sublist(0, 20 * 1024));
    }
    await DbService.documents.put(
        'docA', MusicDocument(id: 'docA', title: 'A', createdAt: 1, updatedAt: 2, pageCount: 10));

    final est = BackupService.estimate();
    expect(est.pageCount, 10);
    final actual = (await BackupService.export(outDir: out)).file.lengthSync();
    expect((est.bytes - actual).abs() / actual, lessThan(0.02),
        reason: 'estimate=${est.bytes} actual=$actual');
    expect(formatBytes(actual), endsWith('MB'));
  });

  test('バックアップ以外の zip は手元のデータを変えずに拒否する', () async {
    await addDoc('docA', 'バイエル', 1);
    final path = '${out.path}/other.zip';
    final enc = ZipFileEncoder()..create(path);
    enc.addArchiveFile(ArchiveFile.string('manifest.json', '{"format":"other"}'));
    await enc.close();

    await expectLater(BackupService.restore(path), throwsA(isA<FormatException>()));
    expect(DbService.documents.get('docA')!.title, 'バイエル');

    final notZip = File('${out.path}/broken.zip')..writeAsStringSync('not a zip');
    await expectLater(
        BackupService.restore(notZip.path), throwsA(isA<FormatException>()));
  });

  test('改名前 (MusicBook) のアプリが書き出した zip も復元できる', () async {
    await addDoc('docA', 'バイエル', 1);
    final backup = await BackupService.export(outDir: out);
    // 旧形式名 (mymusicbook-backup) の manifest に書き換えた zip を作る
    final legacy = '${out.path}/legacy.zip';
    final src = InputFileStream(backup.file.path);
    final enc = ZipFileEncoder()..create(legacy);
    try {
      for (final entry in ZipDecoder().decodeStream(src)) {
        if (!entry.isFile) continue;
        if (entry.name == 'manifest.json') {
          enc.addArchiveFile(ArchiveFile.string('manifest.json',
              jsonEncode(<String, Object>{'format': BackupService.legacyFormatName, 'version': 1})));
        } else {
          enc.addArchiveFile(ArchiveFile.bytes(entry.name, entry.readBytes()!));
        }
      }
    } finally {
      await enc.close();
      src.closeSync();
    }
    DbService.documents.get('docA')!.title = '改名後';

    final r = await BackupService.restore(legacy);
    expect(r.documentCount, 1);
    expect(DbService.documents.get('docA')!.title, 'バイエル');
  });

  test('zip 内の想定外のパス (../ など) は展開しない', () async {
    final path = '${out.path}/evil.zip';
    final enc = ZipFileEncoder()..create(path);
    enc.addArchiveFile(ArchiveFile.string('manifest.json',
        jsonEncode(<String, Object>{'format': BackupService.formatName, 'version': 1})));
    enc.addArchiveFile(ArchiveFile.string(
        'data.json', jsonEncode(<String, Object>{'documents': <Object>[], 'pages': <Object>[]})));
    enc.addArchiveFile(ArchiveFile.string('images/../../evil.webp', 'x'));
    enc.addArchiveFile(ArchiveFile.string('../evil.txt', 'x'));
    await enc.close();

    final r = await BackupService.restore(path);
    expect(r.documentCount, 0);
    expect(File('${root.path}/evil.webp').existsSync(), isFalse);
    expect(File('${root.path}/tmp/evil.txt').existsSync(), isFalse);
  });
}
