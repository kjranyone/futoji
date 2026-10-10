import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 押している間だけ少し縮み、離すと戻るボタン (物理ボタンのような手応え)。
/// タップが成立したとき軽く振動する ([haptic] が true のとき)。
///
/// Material のインクが使えない丸いシャッターなど、独自の見た目のボタン向け。
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    required this.onTap,
    this.scale = 0.92,
    this.haptic = true,
    this.semanticLabel,
  });

  final Widget child;

  /// null のときは押せない (縮まない)。
  final VoidCallback? onTap;

  /// 押している間の縮み (1 = 変化なし)。
  final double scale;

  final bool haptic;
  final String? semanticLabel;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  void didUpdateWidget(covariant PressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 押している途中で無効になったら (撮影開始など) 縮んだまま残さない
    if (widget.onTap == null && _pressed) _pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: enabled
            ? () {
                if (widget.haptic) HapticFeedback.lightImpact();
                widget.onTap!();
              }
            : null,
        child: AnimatedScale(
          scale: _pressed ? widget.scale : 1,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}
