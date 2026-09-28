import 'package:hive_ce_flutter/hive_flutter.dart';

import '../models/adapters.dart';
import '../models/music_document.dart';
import '../models/music_page.dart';

/// Hive の初期化とボックスアクセス。
class DbService {
  DbService._();

  static const String _documentsBox = 'documents';
  static const String _pagesBox = 'pages';
  static const String _settingsBox = 'settings';

  static Future<void> init() async {
    await Hive.initFlutter();
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(MusicDocumentAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(MusicPageAdapter());
    }
    await _openBox<MusicDocument>(_documentsBox);
    await _openBox<MusicPage>(_pagesBox);
    await _openBox<dynamic>(_settingsBox);
  }

  /// 破損時は一度消して作り直す (画像ファイル自体は残る)。
  static Future<void> _openBox<T>(String name) async {
    try {
      await Hive.openBox<T>(name);
    } catch (_) {
      await Hive.deleteBoxFromDisk(name);
      await Hive.openBox<T>(name);
    }
  }

  static Box<MusicDocument> get documents => Hive.box<MusicDocument>(_documentsBox);
  static Box<MusicPage> get pages => Hive.box<MusicPage>(_pagesBox);

  /// 単純なキー/値の設定 (bool / String など)。
  static Box<dynamic> get settings => Hive.box<dynamic>(_settingsBox);
}
