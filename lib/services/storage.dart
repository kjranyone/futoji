import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 画像ファイルの保存先管理。
///   `<アプリ領域>/futoji/images/<pageId>.webp` 本文
///   `<アプリ領域>/futoji/thumbs/<pageId>.webp` サムネイル
class AppPaths {
  AppPaths._();

  static late final String imagesDir;
  static late final String thumbsDir;

  static Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = '${docs.path}${Platform.pathSeparator}futoji';
    imagesDir = '$root${Platform.pathSeparator}images';
    thumbsDir = '$root${Platform.pathSeparator}thumbs';
    await Directory(imagesDir).create(recursive: true);
    await Directory(thumbsDir).create(recursive: true);
  }

  /// [rev] は回転などで画像を書き直したときの版。同じパスに上書きすると、
  /// 表示中の画像がキャッシュから古いまま出続けるので、名前を変えて書く。
  static String imagePathFor(String pageId, [int? rev]) =>
      '$imagesDir${Platform.pathSeparator}${_fileName(pageId, rev)}';

  static String thumbPathFor(String pageId, [int? rev]) =>
      '$thumbsDir${Platform.pathSeparator}${_fileName(pageId, rev)}';

  static String _fileName(String pageId, int? rev) =>
      rev == null ? '$pageId.webp' : '${pageId}_$rev.webp';

  /// ページの画像を消す。[alsoPaths] には書き直した版のパス (MusicPage の
  /// imagePath / thumbPath) を渡す。
  static Future<void> deletePageFiles(String pageId,
      {List<String> alsoPaths = const <String>[]}) async {
    final paths = <String>{imagePathFor(pageId), thumbPathFor(pageId), ...alsoPaths}
      ..remove('');
    for (final path in paths) {
      final f = File(path);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {
          // 消し損ねてもデータ整合性には影響しないため握りつぶす
        }
      }
    }
  }
}
