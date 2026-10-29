import 'dart:math' as math;
import 'dart:ui';

/// 自動撮影モードの状態機械 (純 Dart, 単体テスト可能)。
///
/// 使い方: 検出結果ごとに [feed] を呼ぶ。
/// - 四隅が検出され、紙面が十分大きく、一定時間 (連続チェック) 動かなければ
///   一度だけ `true` (= 撮影せよ) を返す。
/// - 撮影後はクールダウン中になり、同じ位置の紙では再撮影しない。
/// - 紙が動けば (=[rearmMovement] 以上の移動) 再武装、
///   紙が消えたら (検出失敗) 参照をリセットして再武装。
class AutoCaptureController {
  AutoCaptureController({
    this.requiredStableChecks = 3,
    this.stableTolerance = 0.012,
    this.cooldownMs = 3000,
    this.minAreaRatio = 0.18,
    this.rearmMovement = 0.15,
    this.rearmChecks = 2,
    this.countdownMs = 1500,
    this.maxCapturesWithoutClear = 3,
  });

  /// 紙が止まってから撮影するまでの待ち (ms)。画面にカウントダウンを出す。
  /// 撮影の直前に気づけるようにし、動かせば取りやめられるようにするため。
  final int countdownMs;

  /// 紙が一度も画面から外れないまま、この回数を超えて撮ろうとしたら止める
  /// (検出枠の揺れなどで同じ紙を撮り続けるのを防ぐ最後の安全装置)。
  final int maxCapturesWithoutClear;

  DateTime? _stableSince;
  int _capturesSinceClear = 0;
  bool _paused = false;

  /// カウントダウンの開始時刻 (撮影待ちでなければ null)。
  DateTime? get countdownStartedAt =>
      (_lastCaptured == null && _stableSince != null && !_paused) ? _stableSince : null;

  /// 同じ紙を続けて撮りそうになったので止めた (呼び出し側で自動モードを切る)。
  bool get paused => _paused;

  /// 安定判定に必要な連続チェック回数 (検出周期 ~160ms → 約0.5秒)
  final int requiredStableChecks;

  /// 「動いていない」とみなす最大コーナー移動量 (正規化座標の対角比)
  final double stableTolerance;

  /// 撮影後のクールダウン (ms)
  final int cooldownMs;

  /// 撮影に値する最小紙面面積比 (正規化座標系での四角形面積)
  final double minAreaRatio;

  /// 撮影済みの紙からこの以上動いたら「新しい紙」とみなす移動量
  final double rearmMovement;

  /// [rearmMovement] 以上の移動がこの回数続いたら新しい紙とみなす。
  /// 検出枠が 2 通りの形を行き来する (実機で角が約 10% 跳ぶ) と、1 回の跳びで
  /// 「新しい紙」と判定して同じ紙を撮り直していたため、連続で確認する。
  final int rearmChecks;
  int _movedCount = 0;

  DateTime? _cooldownUntil;
  List<Offset>? _previous;
  int _stableCount = 0;
  List<Offset>? _lastCaptured;

  /// 検出結果を与え、撮影すべきとき `true` を返す。
  /// [corners] は正規化座標 [TL,TR,BR,BL]、検出失敗時は null。
  bool feed(List<Offset>? corners, DateTime now) {
    final inCooldown =
        _cooldownUntil != null && now.isBefore(_cooldownUntil!);

    if (corners == null || quadArea(corners) < minAreaRatio) {
      // 紙が見えない → 参照をリセット (次に見えた紙は新規扱い)
      _stableCount = 0;
      _stableSince = null;
      _previous = null;
      if (!inCooldown) {
        _lastCaptured = null;
        _capturesSinceClear = 0;
      }
      return false;
    }

    final movedFromCaptured = _lastCaptured == null
        ? double.infinity
        : maxCornerDelta(corners, _lastCaptured!);

    if (_lastCaptured != null) {
      if (movedFromCaptured < rearmMovement) {
        // さっき撮った紙がまだそこにある → 再撮影しない
        _movedCount = 0;
        _stableCount = 0;
        _stableSince = null;
        _previous = corners;
        return false;
      }
      _movedCount++;
      if (_movedCount < rearmChecks) {
        // 動いたのが 1 回だけ (検出枠の揺れかもしれない) → まだ同じ紙として扱う
        _stableCount = 0;
        _stableSince = null;
        _previous = corners;
        return false;
      }
      if (!inCooldown) {
        // 十分動いた状態が続いた → 新しい紙として再武装
        _lastCaptured = null;
        _movedCount = 0;
      }
    }

    final delta = _previous == null
        ? double.infinity
        : maxCornerDelta(corners, _previous!);
    _previous = List<Offset>.of(corners);

    if (delta <= stableTolerance) {
      _stableCount++;
      _stableSince ??= now;
    } else {
      // 動いた → カウントダウンをやり直す
      _stableCount = 1;
      _stableSince = now;
    }

    final waited = now.difference(_stableSince!).inMilliseconds;
    if (!inCooldown && _stableCount >= requiredStableChecks && waited >= countdownMs) {
      if (_capturesSinceClear >= maxCapturesWithoutClear) {
        _paused = true;
        return false;
      }
      _lastCaptured = List<Offset>.of(corners);
      _cooldownUntil = now.add(Duration(milliseconds: cooldownMs));
      _stableCount = 0;
      _stableSince = null;
      _capturesSinceClear++;
      return true;
    }
    return false;
  }

  /// 現在安定判定を積んでいるか (オーバーレイの色分け用)。
  int get stableCount => _stableCount;

  /// 撮影済みの紙がなく、新しく撮影できる状態か。
  bool get isArmed => _lastCaptured == null;

  /// 手動撮影でも自動再武装の基準を更新する (手動撮影した紙を記憶)。
  void noteManualCapture(List<Offset>? corners, DateTime now) {
    if (corners != null) {
      _lastCaptured = List<Offset>.of(corners);
      _cooldownUntil = now.add(Duration(milliseconds: cooldownMs));
    }
    _stableCount = 0;
  }

  void reset() {
    _movedCount = 0;
    _stableSince = null;
    _capturesSinceClear = 0;
    _paused = false;
    _cooldownUntil = null;
    _previous = null;
    _stableCount = 0;
    _lastCaptured = null;
  }
}

/// 四角形 [TL,TR,BR,BL] の面積 (正規化座標系、0..1)。
double quadArea(List<Offset> q) {
  double a = 0;
  for (int i = 0; i < q.length; i++) {
    final p = q[i];
    final r = q[(i + 1) % q.length];
    a += p.dx * r.dy - r.dx * p.dy;
  }
  return (a / 2).abs();
}

/// 2 つの四角形のコーナー移動量の最大値。
double maxCornerDelta(List<Offset> a, List<Offset> b) {
  if (a.length != b.length) return double.infinity;
  var m = 0.0;
  for (int i = 0; i < a.length; i++) {
    final d = (a[i] - b[i]).distance;
    if (d > m) m = d;
  }
  return m;
}

/// フレーム (センサー向き) を、画面に映る向き・本撮影画像 (EXIF 反映済み) の向きに
/// 合わせるための右回りの角度 (0 / 90 / 180 / 270)。
///
/// [displayRotation] は画面の回転 (Surface.ROTATION_* を度にしたもの)。縦が基本の端末を
/// 縦向きで使うと 0、横が基本のタブレットを縦向きで使うと 90 か 270 になる。
/// 本撮影は CameraX が画面の回転に合わせて向きを付け、プレビューも同じ向きに回して
/// 表示するので、どちらもこの角度になる (CameraX の CameraOrientationUtil と同じ式)。
int frameRotationDegrees({
  required int sensorOrientation,
  required int displayRotation,
  required bool frontFacing,
}) {
  final r = frontFacing
      ? sensorOrientation + displayRotation
      : sensorOrientation - displayRotation;
  return ((r % 360) + 360) % 360;
}

/// フレーム上の正規化コーナーを、EXIF 反映済み画像の正規化座標へ変換する。
///
/// [rotation] ([frameRotationDegrees]) だけ右に回し、フレームと画像で写っている範囲
/// (アスペクト比) が違えば [adjustCornersForAspect] で合わせる。
/// 四隅はフレーム上の位置で [TL,TR,BR,BL] に並んでいるので、回したあとは
/// 画像上の左上から始まるように並べ直す (そのままだと保存したページが回ってしまう)。
List<Offset> mapFrameCornersToImage({
  required List<Offset> corners,
  required int frameW,
  required int frameH,
  required int rotation,
  required double imageAspect,
}) {
  if (frameW <= 0 || frameH <= 0 || imageAspect <= 0) return corners;
  final quarter = rotation % 180 != 0;
  final mapped = startAtTopLeft(<Offset>[
    for (final c in corners) _rotateNormalized(c, rotation),
  ]);
  final mappedAspect = quarter ? frameH / frameW : frameW / frameH;
  // フレームはセンサーの向き (横長) なので、回したあとはセンサーも縦長になる
  return adjustCornersForAspect(mapped, mappedAspect, imageAspect,
      sensorAspect: quarter ? 1 / kSensorAspect : kSensorAspect);
}

/// 四隅の並び (回り方) を保ったまま、左上 (x + y が最小) の点が先頭になるよう巡回させる。
List<Offset> startAtTopLeft(List<Offset> corners) {
  if (corners.length < 2) return corners;
  var start = 0;
  for (int i = 1; i < corners.length; i++) {
    final c = corners[i];
    final s = corners[start];
    if (c.dx + c.dy < s.dx + s.dy) start = i;
  }
  return <Offset>[
    for (int i = 0; i < corners.length; i++) corners[(start + i) % corners.length],
  ];
}

/// 正規化座標の点を、画像ごと右に [degrees] 度回したときの位置。
Offset _rotateNormalized(Offset n, int degrees) {
  switch (((degrees % 360) + 360) % 360) {
    case 90:
      return Offset(1 - n.dy, n.dx);
    case 180:
      return Offset(1 - n.dx, 1 - n.dy);
    case 270:
      return Offset(n.dy, 1 - n.dx);
    default:
      return n;
  }
}

/// カメラフレーム上の正規化コーナーをプレビュー表示上の正規化座標へ変換する。
/// [rotation] は [frameRotationDegrees]、[previewBoxAspect] はオーバーレイを重ねる
/// プレビューボックスのアスペクト比。
/// [mirror] はフロントカメラ用: プレビューが鏡像表示なので、回したあと左右を反転する。
Offset frameToPreview(
  Offset n,
  int frameW,
  int frameH,
  int rotation,
  double previewBoxAspect, {
  bool mirror = false,
}) {
  final mapped = mapFrameCornersToImage(
    corners: <Offset>[n],
    frameW: frameW,
    frameH: frameH,
    rotation: rotation,
    imageAspect: previewBoxAspect,
  ).first;
  return mirror ? Offset(1 - mapped.dx, mapped.dy) : mapped;
}

/// センサー全体のアスペクト比 (横長)。CameraX の既定と同じく 4:3 とみなす。
const double kSensorAspect = 4 / 3;

/// 同じセンサーから取った別のストリーム (アスペクト比 [sourceAspect]) で測った
/// 正規化座標を、ストリーム [targetAspect] の正規化座標へ変換する。
/// [sensorAspect] を含め、アスペクト比はすべて同じ座標の向きで渡す
/// (回して縦にした座標なら、センサーも縦長の 3/4)。
///
/// どちらのストリームもセンサー全体からその比率で最大の範囲を中央で切り出したものと
/// みなす。センサーより横長のストリームは上下が、縦長のストリームは左右が削られる
/// (4:3 のセンサーなら 16:9 は上下が削られる)。範囲外の点は 0..1 の外に出る。
/// アスペクト比がほぼ同じならそのまま返す。
List<Offset> adjustCornersForAspect(
  List<Offset> corners,
  double sourceAspect,
  double targetAspect, {
  double sensorAspect = kSensorAspect,
}) {
  if (sourceAspect <= 0 || targetAspect <= 0 || sensorAspect <= 0) return corners;
  if ((sourceAspect - targetAspect).abs() / targetAspect < 0.02) {
    return corners;
  }
  // センサー全体を 1 としたときに、ストリームが写している幅と高さ
  double spanW(double a) => math.min(1, a / sensorAspect);
  double spanH(double a) => math.min(1, sensorAspect / a);
  final sx = spanW(sourceAspect) / spanW(targetAspect);
  final sy = spanH(sourceAspect) / spanH(targetAspect);
  return <Offset>[
    for (final p in corners)
      Offset(0.5 + (p.dx - 0.5) * sx, 0.5 + (p.dy - 0.5) * sy),
  ];
}

/// 2 点間距離の簡易ユーティリティ (テスト用にも使う)。
double distanceBetween(Offset a, Offset b) {
  return math.sqrt((a.dx - b.dx) * (a.dx - b.dx) +
      (a.dy - b.dy) * (a.dy - b.dy));
}
