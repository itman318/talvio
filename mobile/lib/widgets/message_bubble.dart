
import 'package:flutter/material.dart';

import 'video_note.dart';
import 'message_extras.dart';
import '../theme/chat_theme.dart';
import '../models/models.dart';
import '../utils/format.dart';
import 'avatar.dart';
import 'media_widgets.dart';
import 'extras.dart';
import 'poll_view.dart';
import '../screens/calls_screen.dart';
import '../screens/thread_screen.dart';
import '../screens/user_profile_screen.dart';
import '../screens/story_screens.dart' show StoryThumb;
import 'bot_widgets.dart';
import '../theme/brand.dart';
import 'link_preview.dart';
import 'sticker_widgets.dart';
import 'contact_card.dart';
import 'view_once.dart';
import 'package:provider/provider.dart';
import '../state/chat_store.dart';

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
    this.firstInGroup = true,
    this.lastInGroup = true,
    this.showAvatar = false,
    this.onDiscuss,
    this.onForward,
  });

  /// Channel posts: the round share button next to the post.
  final VoidCallback? onForward;

  /// Channel posts with a discussion group: open it.
  final VoidCallback? onDiscuss;

  /// Consecutive messages from one sender are drawn as one stack (tighter gaps, joined corners).
  final bool firstInGroup;
  final bool lastInGroup;

  /// Groups: the sender's photo next to the last message of their stack.
  final bool showAvatar;

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
    if (m.id <= chat.readUpTo) return Icon(Icons.done_all, size: 15, color: isMine ? const Color(0xFF7DF3DB) : Brand.accent);
    if (m.id <= chat.deliveredUpTo) return Icon(Icons.done_all, size: 15, color: meta);
    return Icon(Icons.done, size: 15, color: meta);
  }

  Widget _body(BuildContext context, Color accent) {
    final m = message;
    if (m.viewOnce) {
      return ViewOnceBubble(message: m, isMine: isMine, color: isMine ? Colors.white : accent, myId: context.read<ChatStore>().myId);
    }
    switch (m.type) {
      case 'image':
        return ClipRRect(borderRadius: BorderRadius.circular(10), child: MessageImage(message: m));
      case 'video':
        return MessageVideo(message: m);
      case 'voice':
        return VoicePlayer(message: m, color: isMine ? Colors.white : accent, isMine: isMine, title: isMine ? 'You' : (m.sender?.name ?? chat.title));
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
    final reserveAvatar = chat.isGroup && !isMine && !_asChannel && !commentMode;
    // a photo / video on its own: no padding around it, the time sits on the picture
    final mediaOnly = (m.type == 'image' || m.type == 'video') &&
        !m.viewOnce &&
        !hasText &&
        m.replyTo == null &&
        m.quote == null &&
        m.storyRef == null &&
        m.forwardedFromName == null &&
        !(showSender && !isMine) &&
        !_asChannel &&
        m.reactions.isEmpty &&
        m.inlineKeyboard.isEmpty;

    final big = m.type == 'text' && m.replyTo == null && m.forwardedFromName == null && m.quote == null && m.inlineKeyboard.isEmpty && !m.viewOnce
        ? bigEmojiCount(m.text)
        : 0;
    if (((m.type == 'sticker' || m.type == 'video_note') && m.replyTo == null) || big > 0) {
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
              if (big > 0)
                BigEmoji(text: m.text.trim(), count: big, fresh: DateTime.now().difference(m.createdAt).inSeconds.abs() < 8)
              else if (m.type == 'video_note')
                VideoNoteBubble(message: m)
              else
                StickerView(message: m),
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
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(m.sender?.name ?? 'Deleted Account',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: colorForId(m.senderId ?? 0), fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            if (m.senderBadge != null) ...[
              const SizedBox(width: 6),
              Text(
                '${m.senderBadge!['text']}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: m.senderBadge!['kind'] == 'tag' ? colorForId(m.senderId ?? 0).withValues(alpha: 0.85) : (dark ? Colors.white54 : const Color(0xFF7A8099)),
                ),
              ),
            ],
          ]),
        ),
      if (m.viaBot != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text('via @${m.viaBot}', style: TextStyle(color: accent, fontWeight: FontWeight.w700, fontSize: 12.5)),
        ),
      if (m.forwardedFromName != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.shortcut_rounded, size: 14, color: accent),
            const SizedBox(width: 4),
            Flexible(
              child: Text('Forwarded from ${m.forwardedFromName}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      if (m.replyTo != null)
        GestureDetector(
          onTap: onReplyTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding: const EdgeInsets.fromLTRB(9, 5, 10, 5),
            decoration: BoxDecoration(
              color: accent.withAlpha(isMine ? 40 : 26),
              border: Border(left: BorderSide(color: accent, width: 3)),
              borderRadius: BorderRadius.circular(8),
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
      if (m.quote != null) _quoteBlock(m.quote!, accent, textColor),
      if (m.storyRef != null) _storyBlock(m.storyRef!, accent, textColor),
      if (m.type != 'text' && !mediaOnly) _body(context, accent),
      if (mediaOnly)
        Stack(children: [
          ClipRRect(borderRadius: BorderRadius.circular(16), child: _body(context, accent)),
          Positioned(
            right: 6,
            bottom: 6,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(color: Colors.black.withAlpha(110), borderRadius: BorderRadius.circular(10)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (m.editedAt != null) const Text('edited · ', style: TextStyle(fontSize: 11, color: Colors.white)),
                  Text(messageTime(m.createdAt), style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                  if (isMine) ...[const SizedBox(width: 3), _ticks(context)],
                ]),
              ),
            ),
          ),
        ]),
      if (m.type != 'text' && hasText) const SizedBox(height: 4),
      if (hasText)
        if (m.type == 'text' && hasChecklist(m.text))
          ChecklistText(message: m, canTick: isMine && !m.isLocal, style: TextStyle(fontSize: 15.5, height: 1.35, color: textColor))
        else
          MessageText(m.text, style: TextStyle(fontSize: 15.5, height: 1.35, color: textColor)),
      if (m.linkPreview != null && m.type == 'text') LinkPreviewCard(data: m.linkPreview!, accent: accent),
      ReactionChips(message: m),
      if (m.inlineKeyboard.isNotEmpty) InlineKeyboard(message: m, botId: m.senderId, botName: m.sender?.name ?? chat.title),
      if (!mediaOnly) const SizedBox(height: 2),
      if (!mediaOnly)
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_asChannel && !m.isLocal) ...[
            Icon(Icons.visibility_outlined, size: 13, color: meta),
            Text(' ${compactNumber(m.views)}  ', style: TextStyle(fontSize: 11, color: meta)),
          ],
          if (m.authorSignature != null) Text('${m.authorSignature} · ', style: TextStyle(fontSize: 11, color: meta)),
          if (m.editedAt != null)
            GestureDetector(
              onTap: m.isLocal ? null : () => showEditHistory(context, m),
              child: Text('edited · ', style: TextStyle(fontSize: 11, color: meta, decoration: TextDecoration.underline, decorationColor: meta)),
            ),
          Text(messageTime(m.createdAt), style: TextStyle(fontSize: 11, color: meta)),
          if (isMine) ...[const SizedBox(width: 3), _ticks(context)],
        ],
      ),
      if (m.sendState == SendState.failed && m.errorText != null)
        Text(m.errorText!, style: TextStyle(color: scheme.error, fontSize: 12)),
      if (_asChannel && onDiscuss != null && !m.isLocal)
        InkWell(
          onTap: onDiscuss,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.forum_rounded, size: 15, color: accent),
              const SizedBox(width: 6),
              Text('Discuss', style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 13)),
            ]),
          ),
        ),
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

    final bubble = GestureDetector(
        onLongPress: onLongPress,
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * (reserveAvatar ? 0.72 : (_asChannel ? 0.84 : 0.78))),
          margin: EdgeInsets.fromLTRB(showAvatar || reserveAvatar ? 0 : 8, firstInGroup ? 3 : 1, 8, lastInGroup ? 3 : 1),
          padding: mediaOnly ? const EdgeInsets.all(3) : const EdgeInsets.fromLTRB(12, 8, 12, 7),
          decoration: BoxDecoration(
            color: isMine && (themed != null || !dark) ? null : bg,
            gradient: isMine ? (themed ?? (dark ? null : Brand.mineGradient)) : null,
            // "Pebble" bubbles: very round, with a soft inner corner instead of a tail.
            // stacked messages share a straighter edge, the last one closes the stack with a round corner
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(isMine ? 20 : (firstInGroup ? 8 : 6)),
              topRight: Radius.circular(isMine ? (firstInGroup ? 8 : 6) : 20),
              bottomLeft: Radius.circular(isMine ? 20 : (lastInGroup ? 20 : 6)),
              bottomRight: Radius.circular(isMine ? (lastInGroup ? 20 : 6) : 20),
            ),
            border: isMine ? null : Border.all(color: dark ? Colors.white.withAlpha(16) : const Color(0xFFE8EBF2), width: 0.8),
            boxShadow: dark
                ? null
                : [
                    BoxShadow(
                      color: (isMine ? (themed?.colors.last ?? Brand.ink) : const Color(0xFF1B2138)).withAlpha(isMine ? 46 : 12),
                      blurRadius: isMine ? 12 : 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
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
      );
    if (_asChannel && onForward != null && !m.isLocal && !m.isSystem) {
      // channel post + a round "share" button beside it, like a magazine feed
      return Align(
        alignment: Alignment.centerLeft,
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Flexible(child: bubble),
          Padding(
            padding: EdgeInsets.only(bottom: lastInGroup ? 5 : 3, right: 6),
            child: Material(
              color: dark ? Colors.white.withAlpha(22) : Colors.black.withAlpha(22),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onForward,
                child: const Padding(padding: EdgeInsets.all(7), child: Icon(Icons.shortcut_rounded, size: 18, color: Colors.white)),
              ),
            ),
          ),
        ]),
      );
    }
    if (!reserveAvatar) {
      return Align(alignment: isMine ? Alignment.centerRight : Alignment.centerLeft, child: bubble);
    }
    // group chats: a column for the sender's photo, shown next to the last message of each stack
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(8, 0, 6, lastInGroup ? 3 : 1),
        child: SizedBox(
          width: 32,
          height: 32,
          child: showAvatar && m.sender != null
              ? GestureDetector(
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => UserProfileScreen(userId: m.sender!.id))),
                  child: ClipOval(child: Avatar(id: m.sender!.id, name: m.sender!.name, url: m.sender!.avatarAbsolute, size: 32)),
                )
              : null,
        ),
      ),
      Flexible(child: Align(alignment: Alignment.centerLeft, child: bubble)),
    ]);
  }

  static final ThemeData _inkTheme = Brand.dark();

  /// "Replied to your story" / "Reacted to your story" with a small preview.
  Widget _storyBlock(Map<String, dynamic> st, Color accent, Color textColor) {
    final reaction = st['reaction'] != null;
    final mention = st['mention'] == true;
    final label = mention
        ? (isMine ? 'You mentioned them in your story' : 'Mentioned you in their story')
        : isMine
            ? (reaction ? 'You reacted to their story' : 'You replied to their story')
            : (reaction ? 'Reacted to your story' : 'Replied to your story');
    final caption = '${st['caption'] ?? ''}';
    final media = st['media'] is Map ? MediaInfo.fromJson(Map<String, dynamic>.from(st['media'] as Map)) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: accent.withAlpha(isMine ? 40 : 26),
        border: Border(left: BorderSide(color: accent, width: 3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(borderRadius: BorderRadius.circular(6), child: SizedBox(width: 36, height: 52, child: StoryThumb(media: media, size: 52))),
        const SizedBox(width: 8),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(mention ? Icons.alternate_email_rounded : (reaction ? Icons.add_reaction_rounded : Icons.amp_stories_rounded), size: 13, color: accent),
              const SizedBox(width: 4),
              Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 12))),
            ]),
            Text(caption.isNotEmpty ? caption : (st['kind'] == 'video' ? 'Video story' : 'Photo story'),
                maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: textColor.withAlpha(210))),
          ]),
        ),
        const SizedBox(width: 4),
      ]),
    );
  }

  /// "Replying privately" quote of a group message.
  Widget _quoteBlock(Map<String, dynamic> q, Color accent, Color textColor) {
    final from = '${q['sender_name'] ?? ''}';
    final where = '${q['chat_title'] ?? ''}';
    final text = '${q['text'] ?? ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.fromLTRB(9, 5, 10, 5),
      decoration: BoxDecoration(
        color: accent.withAlpha(isMine ? 40 : 26),
        border: Border(left: BorderSide(color: accent, width: 3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.reply_all_rounded, size: 13, color: accent),
          const SizedBox(width: 4),
          Flexible(
            child: Text(where.isEmpty ? from : '$from · $where',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 12)),
          ),
        ]),
        Text(text.isEmpty ? _typeLabel('${q['type'] ?? ''}') : stripFormatting(text),
            maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: textColor.withAlpha(210))),
      ]),
    );
  }

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
  const SystemBubble({super.key, required this.text, this.date = false});
  final String text;
  final bool date;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: date ? 10 : 6, horizontal: 24),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          // no blur in the message list (costly while scrolling): a soft solid chip
          child: Builder(
            builder: (_) => Container(
              padding: EdgeInsets.symmetric(horizontal: date ? 14 : 12, vertical: 5),
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF1E2338).withAlpha(230) : Colors.white.withAlpha(225),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: dark ? Colors.white.withAlpha(14) : Colors.white.withAlpha(230), width: 0.8),
              ),
              child: Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: dark ? Colors.white.withAlpha(200) : const Color(0xFF4E556B),
                    fontSize: date ? 12 : 12.5,
                    fontWeight: date ? FontWeight.w700 : FontWeight.w600,
                    letterSpacing: date ? 0.3 : 0,
                  )),
            ),
          ),
        ),
      ),
    );
  }
}

class DateChip extends StatelessWidget {
  const DateChip({super.key, required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) => SystemBubble(text: dateSeparator(date), date: true);
}


final _pictographic = RegExp(r'[\p{Extended_Pictographic}\p{Regional_Indicator}]', unicode: true);
final _emojiOnly = RegExp(r'^(?:[\p{Extended_Pictographic}\p{Regional_Indicator}\p{Emoji_Modifier}\u200D\uFE0F\u20E3#*0-9])+$', unicode: true);

/// 1–3 emoji and nothing else → how many (shown big, without a bubble); otherwise 0.
int bigEmojiCount(String text) {
  final t = text.replaceAll(RegExp(r'\s'), '');
  if (t.isEmpty || t.length > 48 || !_pictographic.hasMatch(t) || !_emojiOnly.hasMatch(t)) return 0;
  final n = t.characters.length;
  return n <= 3 ? n : 0;
}

/// Emoji sent on their own: large, with a soft shadow; a fresh one pops in.
class BigEmoji extends StatelessWidget {
  const BigEmoji({super.key, required this.text, required this.count, this.fresh = false});
  final String text;
  final int count;
  final bool fresh;

  @override
  Widget build(BuildContext context) {
    final size = switch (count) { 1 => 76.0, 2 => 58.0, _ => 48.0 };
    final glyph = Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
      child: Text(
        text,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontSize: size,
          height: 1.15,
          letterSpacing: count > 1 ? 2 : 0,
          shadows: [Shadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 4))],
        ),
      ),
    );
    if (!fresh) return glyph;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.4, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.elasticOut,
      builder: (_, v, child) => Transform.scale(scale: v, child: child),
      child: glyph,
    );
  }
}
