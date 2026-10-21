import 'package:flutter/material.dart';

import '../models/models.dart';
import '../utils/format.dart';
import 'avatar.dart';
import 'media_widgets.dart';
import 'extras.dart';
import 'poll_view.dart';
import '../screens/calls_screen.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.chat,
    required this.isMine,
    required this.showSender,
    this.onLongPress,
    this.onTap,
    this.onReplyTap,
  });

  final Message message;
  final Chat chat;
  final bool isMine;
  final bool showSender;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;
  final VoidCallback? onReplyTap;

  Widget _ticks(BuildContext context) {
    final m = message;
    final colors = ChatColors.of(context);
    if (m.sendState == SendState.sending) return Icon(Icons.schedule, size: 14, color: colors.meta);
    if (m.sendState == SendState.failed) return Icon(Icons.error, size: 15, color: Theme.of(context).colorScheme.error);
    if (chat.isSavedMessages || chat.isChannel) return const SizedBox.shrink();
    if (m.id <= chat.readUpTo) return const Icon(Icons.done_all, size: 15, color: Color(0xFF2AABEE));
    if (m.id <= chat.deliveredUpTo) return Icon(Icons.done_all, size: 15, color: colors.meta);
    return Icon(Icons.done, size: 15, color: colors.meta);
  }

  Widget _body(BuildContext context, Color accent) {
    final m = message;
    switch (m.type) {
      case 'image':
        return ClipRRect(borderRadius: BorderRadius.circular(10), child: MessageImage(message: m));
      case 'video':
        return MessageVideo(message: m);
      case 'voice':
        return VoicePlayer(message: m, color: accent);
      case 'file':
        return MessageFile(message: m, color: accent);
      case 'poll':
        return PollView(message: m, accent: accent);
      case 'location':
        return LocationView(message: m, accent: accent);
      case 'call':
        return CallLogBubble(message: m, isMine: isMine, peer: chat.peer, accent: accent);
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = message;
    final bg = isMine ? ChatColors.of(context).mine : ChatColors.of(context).other;
    final accent = isMine ? const Color(0xFF2AABEE) : colorForId(m.senderId ?? 0);
    final hasText = m.text.isNotEmpty && m.type != 'poll' && m.type != 'location';
    final colors = ChatColors.of(context);

    final children = <Widget>[
      if (chat.isChannel && !isMine)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(chat.title, style: const TextStyle(color: Color(0xFF2AABEE), fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      if (showSender && !isMine && !chat.isChannel)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(m.sender?.name ?? 'Deleted Account',
              style: TextStyle(color: colorForId(m.senderId ?? 0), fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      if (m.forwardedFromName != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('Forwarded from ${m.forwardedFromName}',
              style: TextStyle(color: accent, fontSize: 12, fontStyle: FontStyle.italic)),
        ),
      if (m.replyTo != null)
        GestureDetector(
          onTap: onReplyTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            decoration: BoxDecoration(
              color: accent.withAlpha(25),
              border: Border(left: BorderSide(color: accent, width: 3)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.replyTo!.senderName, style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 12)),
                Text(
                  m.replyTo!.deleted
                      ? 'Deleted message'
                      : (m.replyTo!.text.isNotEmpty ? m.replyTo!.text : _typeLabel(m.replyTo!.type)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      if (m.type != 'text') _body(context, accent),
      if (m.type != 'text' && hasText) const SizedBox(height: 4),
      if (hasText) MessageText(m.text, style: TextStyle(fontSize: 15.5, height: 1.3, color: Theme.of(context).colorScheme.onSurface)),
      ReactionChips(message: m),
      const SizedBox(height: 2),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (chat.isChannel && !m.isLocal) ...[
            Icon(Icons.visibility_outlined, size: 13, color: colors.meta),
            Text(' ${compactNumber(m.views)}  ', style: TextStyle(fontSize: 11, color: colors.meta)),
          ],
          if (m.authorSignature != null) Text('${m.authorSignature} · ', style: TextStyle(fontSize: 11, color: colors.meta)),
          if (m.editedAt != null) Text('edited · ', style: TextStyle(fontSize: 11, color: colors.meta)),
          Text(messageTime(m.createdAt), style: TextStyle(fontSize: 11, color: colors.meta)),
          if (isMine) ...[const SizedBox(width: 3), _ticks(context)],
        ],
      ),
      if (m.sendState == SendState.failed && m.errorText != null)
        Text(m.errorText!, style: TextStyle(color: scheme.error, fontSize: 12)),
    ];

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(isMine ? 14 : 4),
              bottomRight: Radius.circular(isMine ? 4 : 14),
            ),
            boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 2, offset: Offset(0, 1))],
          ),
          child: Column(
            crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }

  static String _typeLabel(String type) => switch (type) {
        'image' => 'Photo',
        'video' => 'Video',
        'voice' => 'Voice message',
        'file' => 'File',
        'poll' => 'Poll',
        _ => 'Message',
      };
}

class SystemBubble extends StatelessWidget {
  const SystemBubble({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(color: Colors.black.withAlpha(40), borderRadius: BorderRadius.circular(12)),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 13)),
      ),
    );
  }
}

class DateChip extends StatelessWidget {
  const DateChip({super.key, required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) => SystemBubble(text: dateSeparator(date));
}
