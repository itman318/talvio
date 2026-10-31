import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/brand.dart';

/// One row of the message menu.
class MessageMenuItem {
  const MessageMenuItem(this.value, this.icon, this.label, {this.danger = false});
  final String value;
  final IconData icon;
  final String label;
  final bool danger;
}

/// Talvio's message menu: tap a message → one card next to it with reactions, the main actions as
/// icon tiles and a short list of the rest. The message itself is not copied or re-drawn. Returns the chosen value ("react:👍", "reply", …) or null.
Future<String?> showMessageMenu(
  BuildContext context, {
  required Rect anchor,
  required bool alignRight,
  required List<String> reactions,
  String? myReaction,
  String? header,
  required List<MessageMenuItem> items,
}) {
  HapticFeedback.lightImpact();
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (ctx, a, __) => _MessageMenu(
      anchor: anchor,
      alignRight: alignRight,
      reactions: reactions,
      myReaction: myReaction,
      header: header,
      items: items,
      animation: a,
    ),
  );
}

class _MessageMenu extends StatelessWidget {
  const _MessageMenu({
    required this.anchor,
    required this.alignRight,
    required this.reactions,
    required this.myReaction,
    required this.header,
    required this.items,
    required this.animation,
  });
  final Rect anchor;
  final bool alignRight;
  final List<String> reactions;
  final String? myReaction;
  final String? header;
  final List<MessageMenuItem> items;
  final Animation<double> animation;

  static const _cardWidth = 268.0;
  static const _rowH = 42.0;
  // the most used actions sit as big icon tiles on top; the rest are a short list
  static const _quickKeys = ['reply', 'copy', 'forward', 'edit', 'pin', 'unpin'];

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? const Color(0xFF1C2036) : Colors.white;
    final tile = dark ? Colors.white.withValues(alpha: 0.06) : const Color(0xFFF3F4FA);
    final fg = dark ? Colors.white : const Color(0xFF1B1F33);
    final topLimit = mq.padding.top + 10;
    final bottomLimit = size.height - mq.padding.bottom - 10;

    final quick = items.where((i) => _quickKeys.contains(i.value)).take(4).toList();
    final rest = items.where((i) => !quick.contains(i)).toList();

    const reactH = 52.0;
    const quickH = 70.0;
    final hasReact = reactions.isNotEmpty;
    final headerH = header == null ? 0.0 : 30.0;
    final cardH = (hasReact ? reactH + 1 : 0) + (quick.isEmpty ? 0 : quickH) + rest.length * _rowH + headerH + 12;
    final width = _cardWidth.clamp(0.0, size.width - 24);

    // Show the card under the message when it fits, otherwise above it, otherwise as high as needed.
    double top;
    if (anchor.bottom + 8 + cardH <= bottomLimit) {
      top = anchor.bottom + 8;
    } else if (anchor.top - 8 - cardH >= topLimit) {
      top = anchor.top - 8 - cardH;
    } else {
      top = (bottomLimit - cardH).clamp(topLimit, bottomLimit);
    }
    final maxH = bottomLimit - top;
    final left = alignRight ? (anchor.right - width).clamp(12.0, size.width - width - 12) : anchor.left.clamp(12.0, size.width - width - 12);
    final fromBottom = top < anchor.top;

    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pop(context),
          // dim everything except the tapped message, which stays where it is
          child: FadeTransition(
            opacity: curved,
            child: CustomPaint(painter: _Spotlight(anchor.inflate(2), Colors.black.withValues(alpha: dark ? 0.42 : 0.2))),
          ),
        ),
      ),
      Positioned(
        top: top,
        left: left.toDouble(),
        width: width,
        child: ScaleTransition(
          scale: Tween(begin: 0.92, end: 1.0).animate(curved),
          alignment: Alignment(alignRight ? 0.8 : -0.8, fromBottom ? 1 : -1),
          child: FadeTransition(
            opacity: curved,
            child: Material(
              color: card,
              elevation: 14,
              shadowColor: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (hasReact) ...[
                      SizedBox(
                        height: reactH,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                          children: [
                            for (var i = 0; i < reactions.length; i++)
                              _Reaction(emoji: reactions[i], selected: reactions[i] == myReaction, delay: i, animation: animation),
                          ],
                        ),
                      ),
                      Divider(height: 1, thickness: 1, color: fg.withValues(alpha: 0.07)),
                    ],
                    if (quick.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                        child: Row(children: [
                          for (final it in quick)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 3),
                                child: Material(
                                  color: tile,
                                  borderRadius: BorderRadius.circular(14),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(14),
                                    onTap: () => Navigator.pop(context, it.value),
                                    child: SizedBox(
                                      height: 56,
                                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                        Icon(it.icon, size: 21, color: Brand.primary),
                                        const SizedBox(height: 4),
                                        Text(it.label,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.1),
                                            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg.withValues(alpha: 0.85))),
                                      ]),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ]),
                      ),
                    for (final it in rest)
                      InkWell(
                        onTap: () => Navigator.pop(context, it.value),
                        child: SizedBox(
                          height: _rowH,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(children: [
                              Icon(it.icon, size: 19, color: it.danger ? const Color(0xFFE5484D) : fg.withValues(alpha: 0.7)),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Text(it.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: it.danger ? const Color(0xFFE5484D) : fg)),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    if (header != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Row(children: [
                          const Icon(Icons.schedule_rounded, size: 13, color: Brand.muted),
                          const SizedBox(width: 6),
                          Expanded(child: Text(header!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: Brand.muted))),
                        ]),
                      ),
                    const SizedBox(height: 4),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _Reaction extends StatelessWidget {
  const _Reaction({required this.emoji, required this.selected, required this.delay, required this.animation});
  final String emoji;
  final bool selected;
  final int delay;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    // the emoji pop in one after another
    final start = (delay * 0.06).clamp(0.0, 0.6);
    final a = CurvedAnimation(parent: animation, curve: Interval(start, (start + 0.4).clamp(0.0, 1.0), curve: Curves.easeOutBack));
    return ScaleTransition(
      scale: a,
      child: InkWell(
        borderRadius: BorderRadius.circular(21),
        onTap: () => Navigator.pop(context, 'react:$emoji'),
        child: Container(
          width: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? Brand.primary.withValues(alpha: 0.16) : null,
          ),
          child: Text(emoji, style: const TextStyle(fontSize: 24)),
        ),
      ),
    );
  }
}

class _Spotlight extends CustomPainter {
  _Spotlight(this.hole, this.color);
  final Rect hole;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(18))),
    );
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Spotlight old) => old.hole != hole || old.color != color;
}
