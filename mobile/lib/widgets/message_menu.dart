import 'dart:ui';

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

/// Talvio's message menu: tap a message → the chat blurs, a reaction pill and a compact card of actions
/// appear right next to the message. Returns the chosen value ("react:👍", "reply", …) or null.
Future<String?> showMessageMenu(
  BuildContext context, {
  required Rect anchor,
  required bool alignRight,
  required List<String> reactions,
  String? myReaction,
  String? header,
  required List<MessageMenuItem> items,
  Widget? preview,
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
      preview: preview,
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
    this.preview,
  });
  final Widget? preview;
  final Rect anchor;
  final bool alignRight;
  final List<String> reactions;
  final String? myReaction;
  final String? header;
  final List<MessageMenuItem> items;
  final Animation<double> animation;

  static const _cardWidth = 214.0;
  static const _rowH = 40.0;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? const Color(0xFF1C2036) : Colors.white;
    final fg = dark ? Colors.white : const Color(0xFF1B1F33);
    final topLimit = mq.padding.top + 12;
    final bottomLimit = size.height - mq.padding.bottom - 12;

    final reactH = reactions.isEmpty ? 0.0 : 50.0;
    final headerH = header == null ? 0.0 : 34.0;
    final menuH = headerH + items.length * _rowH + 10;
    const gap = 6.0;

    // Telegram-like focus: the message itself stays sharp above the blur, reactions over it, actions under it.
    // A long post is shown cut to what fits.
    final room = bottomLimit - topLimit - reactH - menuH - gap * 2;
    final previewH = preview == null ? 0.0 : anchor.height.clamp(0.0, room.clamp(60.0, size.height * 0.45));
    final total = reactH + gap + previewH + gap + menuH;
    var top = (preview == null ? anchor.top : anchor.top) - reactH - gap;
    if (top + total > bottomLimit) top = bottomLimit - total;
    if (top < topLimit) top = topLimit;
    final previewTop = top + reactH + gap;
    final menuTop = previewTop + (preview == null ? 0 : previewH + gap);
    final maxW = size.width - 24;
    final reactW = (reactions.length * 42.0 + 12).clamp(0.0, maxW);
    double left(double w) => alignRight ? (anchor.right - w).clamp(12.0, size.width - w - 12) : anchor.left.clamp(12.0, size.width - w - 12);

    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return Stack(children: [
      // dim + blur the chat behind
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pop(context),
          child: FadeTransition(
            opacity: curved,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: Container(color: Colors.black.withValues(alpha: dark ? 0.35 : 0.18)),
            ),
          ),
        ),
      ),
      if (preview != null)
        Positioned(
          top: previewTop,
          left: 0,
          right: 0,
          height: previewH,
          child: IgnorePointer(
            child: FadeTransition(
              opacity: curved,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: 0,
                  maxHeight: double.infinity,
                  child: SizedBox(width: size.width, child: preview),
                ),
              ),
            ),
          ),
        ),
      if (reactions.isNotEmpty)
        Positioned(
          top: top,
          left: left(reactW),
          width: reactW,
          child: ScaleTransition(
            scale: Tween(begin: 0.85, end: 1.0).animate(curved),
            alignment: alignRight ? Alignment.bottomRight : Alignment.bottomLeft,
            child: FadeTransition(
              opacity: curved,
              child: Material(
                color: card,
                elevation: 10,
                shadowColor: Colors.black.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(25),
                child: SizedBox(
                  height: reactH,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    children: [
                      for (var i = 0; i < reactions.length; i++)
                        _Reaction(emoji: reactions[i], selected: reactions[i] == myReaction, delay: i, animation: animation),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      Positioned(
        top: menuTop,
        left: left(_cardWidth),
        width: _cardWidth,
        child: ScaleTransition(
          scale: Tween(begin: 0.9, end: 1.0).animate(curved),
          alignment: alignRight ? Alignment.topRight : Alignment.topLeft,
          child: FadeTransition(
            opacity: curved,
            child: Material(
              color: card,
              elevation: 12,
              shadowColor: Colors.black.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (header != null) ...[
                    SizedBox(
                      height: headerH - 6,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(children: [
                          const Icon(Icons.schedule_rounded, size: 14, color: Brand.muted),
                          const SizedBox(width: 7),
                          Expanded(child: Text(header!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Brand.muted))),
                        ]),
                      ),
                    ),
                    Divider(height: 4, thickness: 4, color: dark ? Colors.black.withValues(alpha: 0.25) : const Color(0xFFF2F3F8)),
                  ],
                  for (final it in items)
                    InkWell(
                      onTap: () => Navigator.pop(context, it.value),
                      child: SizedBox(
                        height: _rowH,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Row(children: [
                            Icon(it.icon, size: 19, color: it.danger ? const Color(0xFFE5484D) : fg.withValues(alpha: 0.75)),
                            const SizedBox(width: 13),
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
                ]),
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
