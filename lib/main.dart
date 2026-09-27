import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'services/db_service.dart';
import 'services/storage.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
}

class MusicBookApp extends StatelessWidget {
  const MusicBookApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF3B4A9F), // 楽譜・インクを想起させる深い藍色
    );
    return MaterialApp(
      title: 'MusicBook',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        fontFamilyFallback: const <String>[
          'Hiragino Sans',
          'Noto Sans JP',
          'Meiryo',
        ],
      ),
      home: const HomeScreen(),
    );
  }
}
