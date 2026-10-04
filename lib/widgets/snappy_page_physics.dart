import 'package:flutter/widgets.dart';

/// ビューアのページめくり用の物理挙動。標準の PageScrollPhysics は
/// 「半分以上ドラッグするか強く払う」まで戻ってしまい、短いスワイプが効かない感触になる。
///
/// - ページの [turnFraction] (既定 20%) を超えて離せば、その向きへめくる
/// - 離したあとのアニメーションを少し速く収める
class SnappyPageScrollPhysics extends PageScrollPhysics {
  const SnappyPageScrollPhysics({super.parent, this.turnFraction = 0.2});

  final double turnFraction;

  @override
  SnappyPageScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      SnappyPageScrollPhysics(parent: buildParent(ancestor), turnFraction: turnFraction);

  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: 0.5, stiffness: 180, ratio: 1.0);

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    // 端を越えて引っ張ったときなどは標準どおり
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent) ||
        position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final target = targetPixels(position.pixels, position.viewportDimension, velocity);
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(spring, position.pixels, target, velocity,
        tolerance: tolerance);
  }

  /// 離したときの位置と速度から、めくり先のページ位置 (px) を決める。
  @visibleForTesting
  double targetPixels(double pixels, double pageExtent, double velocity) {
    if (pageExtent <= 0) return pixels;
    final page = pixels / pageExtent;
    final base = page.floorToDouble();
    final frac = page - base;
    double target;
    if (velocity > 1) {
      // 次のページへ向かって離した
      target = frac > turnFraction ? base + 1 : base;
    } else if (velocity < -1) {
      // 前のページへ向かって離した
      target = frac < 1 - turnFraction ? base : base + 1;
    } else {
      target = page.roundToDouble();
    }
    return target * pageExtent;
  }
}
