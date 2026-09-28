import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// 撮影 JPEG を「縮小しながら」端末ネイティブのデコーダで読み込む。
///
/// 純 Dart の img.decodeJpg は 4160x3120 の撮影画像で実機 (Lenovo TB J716F) 約 11 秒
/// かかり、撮影のたびに切り抜き画面・自動撮影・保存が止まっていた
/// (./dev.ps1 selftest の decode_ms で計測)。ここではエンジンのコーデック
/// (ImageDescriptor) に目標サイズを渡して縮小デコードさせる。
///
/// EXIF の向きはエンジン側で反映される (向きを反映した後の画像を返す)。
/// test/fast_decode_test.dart で img.bakeOrientation と一致することを検証している。
///
/// dart:ui を使うためメイン isolate から呼ぶこと (デコード自体はエンジンの
/// ワーカースレッドで行われ UI は止まらない)。
Future<img.Image> decodeImageCapped(Uint8List bytes, {required int cap}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  try {
    // descriptor の寸法は向き反映前の場合があるので、長辺側だけを指定して
    // 縦横比はデコーダに任せる (どちらの向きでも長辺は cap 以下になる)。
    final long = math.max(descriptor.width, descriptor.height);
    final scale = long > cap ? cap / long : 1.0;
    final codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * scale).round(),
      targetHeight: (descriptor.height * scale).round(),
    );
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) throw const FormatException('画像を読み込めませんでした');
        // RGBA のまま返す (輝度化・台形補正は 4ch をそのまま扱える)。
        // RGB への詰め替え (convert) は 2600px で実機数秒かかるため行わない。
        return img.Image.fromBytes(
          width: image.width,
          height: image.height,
          bytes: data.buffer,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        );
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}

/// 切り抜き画面・自動撮影判定・自己診断で使うワーク画像の長辺上限。
const int kWorkImageCap = 1000;

/// 撮影 JPEG → 正立・長辺 [kWorkImageCap] px のワーク画像。
/// 切り抜き画面のモデル入力・表示・学習データ保存はすべてこの画像を基準にする。
Future<img.Image> decodeWorkImage(Uint8List bytes) =>
    decodeImageCapped(bytes, cap: kWorkImageCap);
