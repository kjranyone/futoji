import 'dart:ui';

/// 切り抜き画面の結果。
/// corners は「回転後」の画像に対する 0..1 正規化座標 ([TL,TR,BR,BL])。
class CropResult {
  const CropResult({
    required this.corners,
    required this.rotation,
    this.frameWidth,
    this.frameHeight,
    this.sensorOrientation,
  });

  final List<Offset> corners;
  final int rotation;

  /// ライブ検出フレーム由来のコーナーである場合の情報。
  /// フレームはセンサー向きのまま配信されるため、本撮影画像 (EXIF 反映済み) と
  /// 回転・アスペクトが異なる。パイプラインがこの情報でコーナーを写像する。
  /// 切り抜き画面で測った場合は null。
  final int? frameWidth;
  final int? frameHeight;
  final int? sensorOrientation;
}
