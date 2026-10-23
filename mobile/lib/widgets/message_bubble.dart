import 'package:flutter/material.dart';

import 'video_note.dart';
import '../theme/chat_theme.dart';
import '../models/models.dart';
import '../utils/format.dart';
import 'avatar.dart';
import 'media_widgets.dart';
import 'extras.dart';
import 'poll_view.dart';
import '../screens/calls_screen.dart';
import '../screens/thread_screen.dart';
import 'bot_widgets.dart';
import '../theme/brand.dart';
import 'link_preview.dart';
import 'sticker_widgets.dart';
import 'contact_card.dart';

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
    this.commentMode = false,
  });

  final Message message;
  final Chat chat;
  final bool isMine;
  final bool showSender;
  final VoidCallback? onLongPress;
  final VoidCallback? onTap;
  final VoidCallback? onReplyTap;

  /// Rendering a comment under a channel post (shows real authors, no channel header).
  final bool commentMode;

  bool get _asChannel => chat.isChannel && !commentMode;

  Widget _ticks(BuildContext context) {
    final m = message;
    final meta = isMine ? Colors.white.withAlpha(150) : ChatColors.of(context).meta;
    if (m.sendState == SendState.sending) return Icon(Icons.schedule, size: 14, color: meta);
    if (m.sendState == SendState.failed) return Icon(Icons.error, size: 15, color: Theme.of(context).colorScheme.error);
    if (chat.isSavedMessages || _asChannel) return const SizedBox.shrink();
    if (m.id <= chat.readUpTo) return const Icon(Icons.done_all, size: 15, color: Brand.accent);
    if (m.id <= chat.deliveredUpTo) return Icon(Icons.done_all, size: 15, color: meta);
    return Icon(Icons.done, size: 15, color: meta);
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
      case 'video_note':
        return VideoNoteBubble(message: m, size: 200);
      case 'file':
        return MessageFile(message: m, color: accent);
      case 'poll':
        return PollView(message: m, accent: accent);
      case 'location':
        return LocationView(message: m, accent: accent);
      case 'gif':
        return GifView(message: m);
      case 'contact':
        return ContactCardView(message: m, accent: accent);
      case 'call':
        return CallLogBubble(message: m, isMine: isMine, peer: chat.peer, accent: accent);
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final m = message;
    final bg = isMine ? ChatColors.of(context).mine : ChatColors.of(context).other;
    final themed = mineGradientOf(context);
    // My bubbles are deep ink with light text, so they use the dark theme inside.
    final accent = isMine ? Brand.primaryLight : colorForId(m.senderId ?? 0);
    final hasText = m.text.isNotEmpty && m.type != 'poll' && m.type != 'location';
    final colors = ChatColors.of(context);
    final meta = isMine ? Colors.white.withAlpha(150) : colors.meta;
    final textColor = isMine ? Colors.white : scheme.onSurface;

    if ((m.type == 'sticker' || m.type == 'video_note') && m.replyTo == null) {
      // stickers float without a bubble; a small time chip sits under them
      return Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          onLongPress: onLongPress,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            child: Column(crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (showSender && !isMine)
                Text(m.sender?.name ?? '', style: TextStyle(color: colorForId(m.senderId ?? 0), fontWeight: FontWeight.w600, fontSize: 13)),
              if (m.type == 'video_note') VideoNoteBubble(message: m) else StickerView(message: m),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: Colors.black.withAlpha(dark ? 90 : 40), borderRadius: BorderRadius.circular(10)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(messageTime(m.createdAt), style: const TextStyle(fontSize: 11, color: Colors.white)),
                  if (isMine) ...[const SizedBox(width: 3), _ticks(context)],
                ]),
              ),
              ReactionChips(message: m),
            ]),
          ),
        ),
      );
    }

    final children = <Widget>[
      if (_asChannel && !isMine)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(chat.title, style: const TextStyle(color: Brand.primary, fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      if (showSender && !isMine && !_asChannel)
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
                  style: TextStyle(fontSize: 13, color: textColor.withAlpha(210)),
                ),
              ],
            ),
          ),
        ),
      if (m.type != 'text') _body(context, accent),
      if (m.type != 'text' && hasText) const SizedBox(height: 4),
      if (hasText) MessageText(m.text, style: TextStyle(fontSize: 15.5, height: 1.35, color: textColor)),
      if (m.linkPreview != null && m.type == 'text') LinkPreviewCard(data: m.linkPreview!, accent: accent),
      ReactionChips(message: m),
      if (m.replyMarkup != null) InlineKeyboard(message: m, botId: m.senderId, botName: m.sender?.name ?? chat.title),
      const SizedBox(height: 2),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_asChannel && !m.isLocal) ...[
            Icon(Icons.visibility_outlined, size: 13, color: meta),
            Text(' ${compactNumber(m.views)}  ', style: TextStyle(fontSize: 11, color: meta)),
          ],
          if (m.authorSignature != null) Text('${m.authorSignature} · ', style: TextStyle(fontSize: 11, color: meta)),
          if (m.editedAt != null) Text('edited · ', style: TextStyle(fontSize: 11, color: meta)),
          Text(messageTime(m.createdAt), style: TextStyle(fontSize: 11, color: meta)),
          if (isMine) ...[const SizedBox(width: 3), _ticks(context)],
        ],
      ),
      if (m.sendState == SendState.failed && m.errorText != null)
        Text(m.errorText!, style: TextStyle(color: scheme.error, fontSize: 12)),
      if (_asChannel && chat.commentsEnabled && !m.isLocal && !m.isSystem && m.threadId == null)
        InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ThreadScreen(chat: chat, root: m))),
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.chat_bubble_outline, size: 15, color: accent),
              const SizedBox(width: 6),
              Text(m.commentsCount == 0 ? 'Leave a comment' : '${m.commentsCount} comment${m.commentsCount == 1 ? '' : 's'}',
                  style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 13)),
            ]),
          ),
        ),
    ];

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
          decoration: BoxDecoration(
            color: isMine && (themed != null || !dark) ? null : bg,
            gradient: isMine ? (themed ?? (dark ? null : Brand.mineGradient)) : null,
            // "Pebble" bubbles: very round, with a soft inner corner instead of a tail.
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(isMine ? 20 : 8),
              topRight: Radius.circular(isMine ? 8 : 20),
              bottomLeft: const Radius.circular(20),
              bottomRight: const Radius.circular(20),
            ),
            border: isMine || dark ? null : Border.all(color: const Color(0xFFE6E9F1)),
            boxShadow: [BoxShadow(color: (isMine ? Brand.ink : const Color(0xFF1B2138)).withAlpha(isMine ? 40 : 14), blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: Theme(
            data: isMine ? _inkTheme : Theme.of(context),
            child: Column(
              crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      ),
    );
  }

  static final ThemeData _inkTheme = Brand.dark();

  static String _typeLabel(String type) => switch (type) {
        'image' => 'Photo',
        'video' => 'Video',
        'voice' => 'Voice message',
        'video_note' => 'Video message',
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
