import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import 'avatar.dart';

/// A small card that drops in from the top when a message arrives in another chat while the app is open,
/// so nothing slips by. Tap → open the chat, swipe up → dismiss. Only one at a time (newest wins).
class InAppBanner {
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(OverlayState overlay, {required Chat chat, required Message message, required VoidCallback onTap}) {
    hide();
    HapticFeedback.lightImpact();
    final who = chat.isMulti && message.sender != null ? '${message.sender!.name}: ' : '';
    final entry = OverlayEntry(
      builder: (ctx) => _BannerCard(
        title: chat.title,
        text: '$who${message.preview}',
        avatar: Avatar(id: chat.id, name: chat.title, url: chat.avatarAbsolute, size: 40),
        onTap: () {
          hide();
          onTap();
        },
        onDismiss: hide,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(const Duration(seconds: 4), hide);
  }

  static void hide() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

class _BannerCard extends StatefulWidget {
  const _BannerCard({required this.title, required this.text, required this.avatar, required this.onTap, required this.onDismiss});
  final String title;
  final String text;
  final Widget avatar;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  State<_BannerCard> createState() => _BannerCardState();
}

class _BannerCardState extends State<_BannerCard> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 260))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = MediaQuery.paddingOf(context).top;
    return Positioned(
      top: top + 6,
      left: 10,
      right: 10,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, -1.4), end: Offset.zero).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic)),
        child: GestureDetector(
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -100) widget.onDismiss();
          },
          child: Material(
            elevation: 10,
            shadowColor: Colors.black38,
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
                child: Row(children: [
                  widget.avatar,
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                      const SizedBox(height: 2),
                      Text(widget.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
