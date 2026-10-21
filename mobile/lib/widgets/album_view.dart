import 'package:flutter/material.dart';

import '../models/models.dart';
import '../utils/format.dart';
import 'extras.dart';
import 'media_widgets.dart';

/// Several photos sent together, shown as one bubble with a grid.
class AlbumBubble extends StatelessWidget {
  const AlbumBubble({super.key, required this.items, required this.isMine, this.onLongPress, this.senderName});
  final List<Message> items; // oldest first
  final bool isMine;
  final VoidCallback? onLongPress;
  final String? senderName;

  @override
  Widget build(BuildContext context) {
    final colors = ChatColors.of(context);
    final width = MediaQuery.of(context).size.width * 0.72;
    final caption = items.map((m) => m.text).where((t) => t.isNotEmpty).join('\n');
    final last = items.last;
    final cols = items.length == 1 ? 1 : (items.length == 4 || items.length == 2 ? 2 : 3);
    final cell = (width - 4 * (cols - 1)) / cols;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          width: width + 12,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: isMine ? colors.mine : colors.other, borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (senderName != null)
              Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 4), child: Text(senderName!, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: items
                  .map((m) => ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: cell,
                          height: cell,
                          child: m.media == null ? const ColoredBox(color: Colors.black12) : FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: MessageImage(message: m, maxWidth: cell)),
                        ),
                      ))
                  .toList(),
            ),
            if (caption.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(4, 6, 4, 0), child: MessageText(caption)),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 2, right: 4),
                child: Text('${items.length} photos · ${messageTime(last.createdAt)}', style: TextStyle(fontSize: 11, color: colors.meta)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
