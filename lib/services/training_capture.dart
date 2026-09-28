import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'db_service.dart';
import 'ids.dart';
import 'quad_label.dart';

/// 切り抜き画面で確定した「画像 + 正解四隅 + そのときのモデル予測」を
/// 学習・評価用データとして端末に保存する (設定で ON のときのみ)。
///
/// 保存先 (Android): `/sdcard/Android/data/<applicationId>/files/training_captures/`
///   → `adb pull /sdcard/Android/data/com.kjranyone.mymusicbook/files/training_captures`
/// 取り出したフォルダはそのまま `test/paper_net_eval_test.dart` の評価セットになる。
class TrainingCapture {
  TrainingCapture._();

  static const String _enabledKey = 'collect_training_data';
  static const String dirName = 'training_captures';

  /// 手修正とみなす四隅の移動量 (正規化座標)。
  static const double _editEpsilon = 0.002;

  static bool get enabled =>
      DbService.settings.get(_enabledKey, defaultValue: false) as bool;

  static Future<void> setEnabled(bool value) =>
      DbService.settings.put(_enabledKey, value);

  /// 保存先ディレクトリ。Android は adb で取り出せる外部アプリ領域を使う。
  static Future<Directory> directory() async {
    Directory? base;
    if (Platform.isAndroid) {
      base = await getExternalStorageDirectory();
    }
    base ??= await getApplicationDocumentsDirectory();
    return Directory('${base.path}${Platform.pathSeparator}$dirName');
  }

  /// 保存済みサンプル数 (json の数)。
  static Future<int> count() async {
    final dir = await directory();
    if (!await dir.exists()) return 0;
    return dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .length;
  }

  /// ユーザーが四隅を動かしたか (予測なし = 手で合わせた扱い)。
  static bool isEdited(List<Offset>? predicted, List<Offset> corners) {
    if (predicted == null || predicted.length != corners.length) return true;
    for (int i = 0; i < corners.length; i++) {
      if ((predicted[i] - corners[i]).distance > _editEpsilon) return true;
    }
    return false;
  }

  /// 1 件保存する。[jpeg] は四隅の座標系と同じ (正立・回転反映済み) 画像。
  /// 失敗しても撮影フローは止めない (ログのみ)。
  static Future<void> save({
    required Uint8List jpeg,
    required int width,
    required int height,
    required List<Offset> corners,
    required List<Offset>? predicted,
  }) async {
    try {
      final dir = await directory();
      await dir.create(recursive: true);
      final id = newId();
      final label = QuadLabel(
        image: '$id.jpg',
        width: width,
        height: height,
        corners: corners,
        predicted: predicted,
        edited: isEdited(predicted, corners),
        source: 'app_crop',
        createdAt: DateTime.now(),
      );
      final sep = Platform.pathSeparator;
      await File('${dir.path}$sep$id.jpg').writeAsBytes(jpeg);
      // json は画像の後に書く (json があれば画像も揃っている、を保証)
      await File('${dir.path}$sep$id.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert(label.toJson()));
    } catch (e) {
      debugPrint('TrainingCapture: save failed ($e)');
    }
  }
}
