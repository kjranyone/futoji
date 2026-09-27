import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 画像ファイルの保存先管理。
///   `<アプリ領域>/musicbook/images/<pageId>.webp` 本文
///   `<アプリ領域>/musicbook/thumbs/<pageId>.webp` サムネイル
class AppPaths {
  AppPaths._();

  static late final String imagesDir;
  static late final String thumbsDir;

  static Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = '${docs.path}${Platform.pathSeparator}musicbook';
    imagesDir = '$root${Platform.pathSeparator}images';
    thumbsDir = '$root${Platform.pathSeparator}thumbs';
    await Directory(imagesDir).create(recursive: true);
    await Directory(thumbsDir).create(recursive: true);
  }

  static String imagePathFor(String pageId) => '$imagesDir${Platform.pathSeparator}$pageId.webp';

  static String thumbPathFor(String pageId) => '$thumbsDir${Platform.pathSeparator}$pageId.webp';

  static Future<void> deletePageFiles(String pageId) async {
    for (final path in [imagePathFor(pageId), thumbPathFor(pageId)]) {
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
