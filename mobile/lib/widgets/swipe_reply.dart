import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Swipe a message to the right to reply; double-tap it to send ❤️.
class SwipeReply extends StatefulWidget {
  const SwipeReply({super.key, required this.child, this.onReply, this.onDoubleTap});
  final Widget child;
  final VoidCallback? onReply;
  final VoidCallback? onDoubleTap;

  @override
  State<SwipeReply> createState() => _SwipeReplyState();
}

class _SwipeReplyState extends State<SwipeReply> with TickerProviderStateMixin {
  static const _trigger = 56.0;
  static const _max = 76.0;
  double _dx = 0;
  bool _armed = false;
  late final AnimationController _back = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))
    ..addListener(() => setState(() => _dx = _from * (1 - Curves.easeOut.transform(_back.value))));
  double _from = 0;
  late final AnimationController _heart = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void dispose() {
    _back.dispose();
    _heart.dispose();
    super.dispose();
  }

  void _end() {
    if (_armed) widget.onReply?.call();
    _armed = false;
    _from = _dx;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dx / _trigger).clamp(0.0, 1.0);
    Widget content = Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
      Transform.translate(offset: Offset(_dx, 0), child: widget.child),
      if (_dx > 4)
        Positioned(
          left: 6,
          child: Opacity(
            opacity: progress,
            child: Transform.scale(
              scale: 0.6 + progress * 0.4,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(color: Colors.black.withAlpha(_armed ? 70 : 40), shape: BoxShape.circle),
                child: const Icon(Icons.reply_rounded, color: Colors.white, size: 19),
              ),
            ),
          ),
        ),
      // ❤️ pops up after a double-tap
      AnimatedBuilder(
        animation: _heart,
        builder: (_, __) {
          if (!_heart.isAnimating) return const SizedBox.shrink();
          final t = _heart.value;
          return IgnorePointer(
            child: Opacity(
              opacity: t < 0.7 ? 1 : (1 - t) / 0.3,
              child: Transform.scale(scale: 0.4 + Curves.elasticOut.transform(t) * 0.8, child: const Text('❤️', style: TextStyle(fontSize: 46))),
            ),
          );
        },
      ),
    ]);
    if (widget.onReply == null && widget.onDoubleTap == null) return content;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTap: widget.onDoubleTap == null
          ? null
          : () {
              HapticFeedback.lightImpact();
              _heart.forward(from: 0);
              widget.onDoubleTap!();
            },
      onHorizontalDragUpdate: widget.onReply == null
          ? null
          : (d) {
              if (_back.isAnimating) _back.stop();
              final next = (_dx + d.delta.dx * (_dx > _trigger ? 0.35 : 1)).clamp(0.0, _max);
              final armed = next >= _trigger;
              if (armed && !_armed) HapticFeedback.selectionClick();
              setState(() {
                _dx = next;
                _armed = armed;
              });
            },
      onHorizontalDragEnd: widget.onReply == null ? null : (_) => _end(),
      onHorizontalDragCancel: widget.onReply == null ? null : _end,
      child: content,
    );
  }
}
