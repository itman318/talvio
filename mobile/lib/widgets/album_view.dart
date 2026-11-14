import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../screens/user_profile_screen.dart';
import '../theme/brand.dart';
import '../theme/chat_theme.dart';
import '../utils/format.dart';
import 'avatar.dart';
import 'extras.dart';
import 'media_widgets.dart';
import 'poll_view.dart' show ReactionChips;

/// Several photos sent together, shown as one bubble: a tight mosaic, the caption under it,
/// and the time (with ticks on my own) on the last photo — the same look as a single photo.
class AlbumBubble extends StatelessWidget {
  const AlbumBubble({
    super.key,
    required this.items,
    required this.chat,
    required this.isMine,
    this.onLongPress,
    this.onTap,
    this.senderName,
    this.sender,
    this.firstInGroup = true,
    this.lastInGroup = true,
    this.showAvatar = false,
  });

  final List<Message> items; // oldest first
  final Chat chat;
  final bool isMine;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;
  final String? senderName;
  final AppUser? sender;
  final bool firstInGroup;
  final bool lastInGroup;
  final bool showAvatar;

  /// How many photos sit in each row (3 photos are special: one large, two small beside it).
  static List<int> rowsFor(int n) {
    if (n <= 2) return [n];
    final rows = <int>[];
    var left = n;
    // rows of three; a lone last photo would look lost, so the remainder becomes rows of two
    while (left > 0) {
      if (left == 4) {
        rows..add(2)..add(2);
        break;
      }
      if (left == 2) {
        rows.add(2);
        break;
      }
      rows.add(3);
      left -= 3;
    }
    rows.sort(); // wider photos first
    return rows;
  }

  Widget _cell(Message m, double w, double h) => SizedBox(
        width: w,
        height: h,
        child: m.media == null && m.localFilePath == null
            ? const ColoredBox(color: Colors.black12)
            : FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: MessageImage(message: m, maxWidth: math.max(w, h))),
      );

  Widget _mosaic(double width) {
    const gap = 2.0;
    final n = items.length;
    if (n == 3) {
      final big = (width - gap) * 0.64;
      final small = width - gap - big;
      final h = big * 1.02;
      return Row(mainAxisSize: MainAxisSize.min, children: [
        _cell(items[0], big, h),
        const SizedBox(width: gap),
        Column(mainAxisSize: MainAxisSize.min, children: [
          _cell(items[1], small, (h - gap) / 2),
          const SizedBox(height: gap),
          _cell(items[2], small, (h - gap) / 2),
        ]),
      ]);
    }
    final rows = <Widget>[];
    var k = 0;
    for (final count in rowsFor(n)) {
      final w = (width - gap * (count - 1)) / count;
      final h = count == 1 ? w * 0.75 : (count == 2 ? w * 0.92 : w);
      if (rows.isNotEmpty) rows.add(const SizedBox(height: gap));
      rows.add(Row(mainAxisSize: MainAxisSize.min, children: [
        for (var c = 0; c < count && k < n; c++) ...[
          if (c > 0) const SizedBox(width: gap),
          _cell(items[k++], w, h),
        ],
      ]));
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  Widget _tick(BuildContext context, Color meta, {bool onPhoto = false}) {
    if (items.any((m) => m.sendState == SendState.failed)) return Icon(Icons.error, size: 15, color: Theme.of(context).colorScheme.error);
    if (items.any((m) => m.sendState == SendState.sending)) return Icon(Icons.schedule, size: 14, color: meta);
    if (chat.isSavedMessages || chat.isChannel) return const SizedBox.shrink();
    final id = items.last.id;
    final soft = softMineOf(context);
    if (id <= chat.readUpTo) return Icon(Icons.done_all, size: 15, color: onPhoto || !soft ? const Color(0xFF7DF3DB) : MineInk.accent);
    if (id <= chat.deliveredUpTo) return Icon(Icons.done_all, size: 15, color: meta);
    return Icon(Icons.done, size: 15, color: meta);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ChatColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final soft = isMine && softMineOf(context);
    final themed = mineGradientOf(context);
    final reserveAvatar = chat.isGroup && !isMine;
    final width = math.min(MediaQuery.of(context).size.width * (reserveAvatar ? 0.68 : 0.74), 340.0);
    final caption = items.map((m) => m.text).where((t) => t.isNotEmpty).join('\n');
    final withReactions = items.where((m) => m.reactions.isNotEmpty).toList();
    final last = items.last;
    final textColor = soft ? MineInk.ink : isMine ? Colors.white : Theme.of(context).colorScheme.onSurface;
    final meta = soft ? const Color(0xFF8A85AD) : isMine ? Colors.white.withAlpha(150) : colors.meta;
    final plain = caption.isEmpty && withReactions.isEmpty; // photos only: the time sits on the last photo
    final radius = BorderRadius.only(
      topLeft: Radius.circular(isMine ? 20 : (firstInGroup ? 8 : 6)),
      topRight: Radius.circular(isMine ? (firstInGroup ? 8 : 6) : 20),
      bottomLeft: Radius.circular(isMine ? 20 : (lastInGroup ? 20 : 6)),
      bottomRight: Radius.circular(isMine ? (lastInGroup ? 20 : 6) : 20),
    );

    final bubble = GestureDetector(
      onLongPress: onLongPress,
      onTap: onTap,
      child: Container(
        width: width + 6,
        margin: EdgeInsets.fromLTRB(reserveAvatar ? 0 : 8, firstInGroup ? 3 : 1, 8, lastInGroup ? 3 : 1),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: isMine && (themed != null || !dark) ? null : (isMine ? colors.mine : colors.other),
          gradient: isMine ? (themed ?? (dark ? null : Brand.mineGradient)) : null,
          borderRadius: radius,
          border: soft
              ? Border.all(color: const Color(0xFFD8CFFF), width: 0.8)
              : isMine ? null : Border.all(color: dark ? Colors.white.withAlpha(16) : const Color(0xFFE6E8F0), width: 0.8),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (senderName != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 4, 9, 5),
              child: Text(senderName!,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: colorForId(last.senderId ?? 0), fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(senderName != null ? 6 : math.max(radius.topLeft.x - 3, 4)),
                topRight: Radius.circular(senderName != null ? 6 : math.max(radius.topRight.x - 3, 4)),
                bottomLeft: Radius.circular(plain ? math.max(radius.bottomLeft.x - 3, 4) : 6),
                bottomRight: Radius.circular(plain ? math.max(radius.bottomRight.x - 3, 4) : 6),
              ),
              child: _mosaic(width),
            ),
            if (plain)
              Positioned(
                right: 6,
                bottom: 6,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(color: Colors.black.withAlpha(110), borderRadius: BorderRadius.circular(10)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(messageTime(last.createdAt), style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                      if (isMine) ...[const SizedBox(width: 3), _tick(context, Colors.white.withAlpha(200), onPhoto: true)],
                    ]),
                  ),
                ),
              ),
          ]),
          if (!plain)
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 6, 9, 4),
              child: Theme(
                data: isMine && !soft ? _ink : Theme.of(context),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  if (caption.isNotEmpty) MessageText(caption, style: TextStyle(fontSize: 15.5, height: 1.35, color: textColor)),
                  for (final m in withReactions) ReactionChips(message: m),
                  const SizedBox(height: 2),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(messageTime(last.createdAt), style: TextStyle(fontSize: 11, color: meta)),
                      if (isMine) ...[const SizedBox(width: 3), _tick(context, meta)],
                    ]),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );

    if (!reserveAvatar) return Align(alignment: isMine ? Alignment.centerRight : Alignment.centerLeft, child: bubble);
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(8, 0, 6, lastInGroup ? 3 : 1),
        child: SizedBox(
          width: 32,
          height: 32,
          child: showAvatar && sender != null
              ? GestureDetector(
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfileScreen(userId: sender!.id))),
                  child: ClipOval(child: Avatar(id: sender!.id, name: sender!.name, url: sender!.avatarAbsolute, size: 32)),
                )
              : null,
        ),
      ),
      Flexible(child: Align(alignment: Alignment.centerLeft, child: bubble)),
    ]);
  }

  static final ThemeData _ink = Brand.dark();
}
