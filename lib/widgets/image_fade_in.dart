import 'package:flutter/material.dart';

/// `Image.frameBuilder` に渡す: 読み込みが終わった画像をふわっと出す。
///
/// キャッシュから同期に出せたとき (一覧をスクロールして戻ったときなど) はそのまま出し、
/// 毎回フェードして煩わしくならないようにする。
Widget fadeInImageFrame(
  BuildContext context,
  Widget child,
  int? frame,
  bool wasSynchronouslyLoaded,
) {
  if (wasSynchronouslyLoaded) return child;
  return AnimatedOpacity(
    opacity: frame == null ? 0 : 1,
    duration: const Duration(milliseconds: 180),
    curve: Curves.easeOut,
    child: child,
  );
}
