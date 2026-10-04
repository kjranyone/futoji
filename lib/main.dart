import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'licenses.dart';
import 'screens/home_screen.dart';
import 'services/db_service.dart';
import 'services/self_test.dart';
import 'services/storage.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBundledLicenses();
  await DbService.init();
  await AppPaths.init();
  final appState = AppState();
  await appState.cleanupEmptyDocuments();
  await appState.refreshDocuments();
  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const MusicBookApp(),
    ),
  );
  // 開発用: 設定で許可され、端末に selftest/RUN があるときだけ紙面検出の自己診断を 1 回実行する
  unawaited(SelfTest.runIfRequested());
}

class MusicBookApp extends StatelessWidget {
  const MusicBookApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MusicBook',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomeScreen(),
    );
  }
}

/// アプリのテーマ (テストからも使う)。
ThemeData buildAppTheme() => ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF3B4A9F), // 楽譜・インクを想起させる深い藍色
      ),
      useMaterial3: true,
      // 全プラットフォームで iOS と同じ遷移にし、画面の左端からのスワイプで戻れるようにする
      // (Android の 3 ボタンナビゲーションでも使える)。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      fontFamilyFallback: const <String>[
        'Hiragino Sans',
        'Noto Sans JP',
        'Meiryo',
      ],
    );
