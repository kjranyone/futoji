import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'licenses.dart';
import 'screens/home_screen.dart';
import 'theme.dart';
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
