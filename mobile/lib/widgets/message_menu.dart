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

/// Hushavia's message menu: tap a message → a reactions pill and a compact list of actions right next to it. The message itself is not copied or re-drawn. Returns the chosen value ("react:👍", "reply", …) or null.
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
    transitionDuration: const Duration(milliseconds: 140),
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

  static const _listWidth = 232.0;
  static const _rowH = 44.0;
  static const _pillH = 50.0;
  static const _gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = dark ? const Color(0xFF1C2036) : Colors.white;
    final fg = dark ? Colors.white : const Color(0xFF1B1F33);
    final topLimit = mq.padding.top + 8;
    final bottomLimit = size.height - mq.padding.bottom - mq.viewInsets.bottom - 8;

    final hasReact = reactions.isNotEmpty;
    final pillW = (reactions.length * 44.0 + 12).clamp(0.0, size.width - 24);
    final listH = items.length * _rowH + (header == null ? 0 : 30) + 10;
    final blockH = (hasReact ? _pillH + _gap : 0) + listH;

    // Right next to the message: below it if there's room, else above it, else on the roomier side
    // (the list then scrolls) — never far away from the message that was tapped.
    final visTop = anchor.top.clamp(topLimit, bottomLimit);
    final visBottom = anchor.bottom.clamp(topLimit, bottomLimit);
    final below = bottomLimit - visBottom - 8;
    final above = visTop - topLimit - 8;
    double top;
    double maxBlock;
    if (blockH <= below) {
      top = visBottom + 8;
      maxBlock = below;
    } else if (blockH <= above) {
      top = visTop - 8 - blockH;
      maxBlock = above;
    } else if (below >= 220 || above >= 220) {
      final useBelow = below >= above;
      maxBlock = useBelow ? below : above;
      top = useBelow ? visBottom + 8 : visTop - 8 - maxBlock;
    } else {
      // a very tall message fills the screen: float the menu over its middle
      maxBlock = (bottomLimit - topLimit) * 0.8;
      top = ((visTop + visBottom) / 2 - blockH.clamp(0, maxBlock) / 2).clamp(topLimit, bottomLimit - blockH.clamp(0, maxBlock));
    }
    final listMax = (maxBlock - (hasReact ? _pillH + _gap : 0)).clamp(_rowH * 2.5, listH);
    final opensDown = top >= visBottom;

    double sideX(double w) {
      final x = alignRight ? anchor.right - w : anchor.left;
      return x.clamp(10.0, size.width - w - 10);
    }

    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    Widget appear(Widget child, Alignment origin) => FadeTransition(
          opacity: curved,
          child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(curved), alignment: origin, child: child),
        );
    final origin = Alignment(alignRight ? 0.9 : -0.9, opensDown ? -1 : 1);

    final pill = Material(
      color: card,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      borderRadius: BorderRadius.circular(_pillH / 2),
      child: SizedBox(
        height: _pillH,
        width: pillW,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          children: [
            for (var i = 0; i < reactions.length; i++) _Reaction(emoji: reactions[i], selected: reactions[i] == myReaction, delay: i, animation: animation),
          ],
        ),
      ),
    );

    final list = Material(
      color: card,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.28),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: listMax, minWidth: _listWidth, maxWidth: _listWidth),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final it in items)
              InkWell(
                onTap: () => Navigator.pop(context, it.value),
                child: SizedBox(
                  height: _rowH,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(children: [
                      Icon(it.icon, size: 20, color: it.danger ? const Color(0xFFE5484D) : fg.withValues(alpha: 0.62)),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(it.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.15),
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: it.danger ? const Color(0xFFE5484D) : fg)),
                      ),
                    ]),
                  ),
                ),
              ),
            if (header != null) ...[
              Divider(height: 9, thickness: 1, color: fg.withValues(alpha: 0.07)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                child: Text(header!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Brand.muted)),
              ),
            ],
          ]),
        ),
      ),
    );

    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pop(context),
          child: const SizedBox.expand(),
        ),
      ),
      Positioned(
        top: top,
        left: 0,
        right: 0,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (hasReact) ...[
            Padding(padding: EdgeInsets.only(left: sideX(pillW)), child: appear(pill, origin)),
            const SizedBox(height: _gap),
          ],
          Padding(padding: EdgeInsets.only(left: sideX(_listWidth)), child: appear(list, origin)),
        ]),
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
    final start = (delay * 0.04).clamp(0.0, 0.4);
    final a = CurvedAnimation(parent: animation, curve: Interval(start, (start + 0.4).clamp(0.0, 1.0), curve: Curves.easeOutBack));
    return ScaleTransition(
      scale: a,
      child: InkWell(
        borderRadius: BorderRadius.circular(21),
        onTap: () => Navigator.pop(context, 'react:$emoji'),
        child: Container(
          width: 42,
          height: 42,
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
