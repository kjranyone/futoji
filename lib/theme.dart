import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// 楽譜・インクを想起させる深い藍色
const Color _seed = Color(0xFF3B4A9F);

const PageTransitionsTheme _transitions = PageTransitionsTheme(
  // 全プラットフォームで iOS と同じ遷移にし、画面の左端からのスワイプで戻れるようにする
  // (Android の 3 ボタンナビゲーションでも使える)。
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: CupertinoPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
  },
);

const List<String> _fonts = <String>['Hiragino Sans', 'Noto Sans JP', 'Meiryo'];

/// アプリのテーマ (テストからも使う)。
ThemeData buildAppTheme() => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: _seed),
      useMaterial3: true,
      pageTransitionsTheme: _transitions,
      fontFamilyFallback: _fonts,
    );

/// ブック一覧・ページ一覧の黒背景テーマ (ビューアの黒と揃える)。
/// ここから開くダイアログやメニューも同じ暗い配色になる。
ThemeData buildBrowseTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark)
      .copyWith(surface: Colors.black);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: Colors.black,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
    ),
    pageTransitionsTheme: _transitions,
    fontFamilyFallback: _fonts,
  );
}
