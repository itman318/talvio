import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/models.dart';
import '../screens/channel_screens.dart' show PublicChatPreviewScreen;
import '../screens/chat_screen.dart';
import '../screens/new_chat_screen.dart' show openInviteCode;
import '../state/chat_store.dart';
import '../utils/format.dart';

/// Full shareable links, like t.me links:
///   public  → https://server/c/<username>
///   private → https://server/join/<invite code>
String publicChatLink(String username) => '${AppConfig.serverUrl}/c/$username';
String inviteChatLink(String code) => '${AppConfig.serverUrl}/join/$code';

/// The best link for this chat (public if it has a username, else the invite link if I can see it).
String? chatLinkOf(Chat chat) {
  final u = chat.username;
  if (u != null && u.isNotEmpty) return publicChatLink(u);
  final code = chat.inviteCode;
  return code == null ? null : inviteChatLink(code);
}

/// ('c', username) or ('join', code) for our links: talvio://c/x, https://<our server>/join/x …
(String, String)? parseChatLink(String raw) {
  final s = raw.trim();
  final deep = RegExp(r'^talvio://(c|join)/([A-Za-z0-9_\-]{3,64})/?(\?.*)?$').firstMatch(s);
  if (deep != null) return (deep.group(1)!, deep.group(2)!);
  final uri = Uri.tryParse(s);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return null;
  final ours = Uri.tryParse(AppConfig.serverUrl);
  if (ours == null || uri.host != ours.host) return null;
  final seg = uri.pathSegments.where((x) => x.isNotEmpty).toList();
  if (seg.length == 2 && (seg[0] == 'c' || seg[0] == 'join') && RegExp(r'^[A-Za-z0-9_\-]{3,64}$').hasMatch(seg[1])) return (seg[0], seg[1]);
  return null;
}

/// Opens a Talvio chat link inside the app. Returns false when [link] isn't one of ours.
Future<bool> openChatLink(BuildContext context, String link) async {
  final p = parseChatLink(link);
  if (p == null) return false;
  if (p.$1 == 'join') {
    await openInviteCode(context, p.$2);
    return true;
  }
  final store = context.read<ChatStore>();
  // bots: t.me-style links, optionally with ?start=<payload> → "/start <payload>"
  final start = RegExp(r'[?&]start=([A-Za-z0-9_\-]{1,64})').firstMatch(link)?.group(1);
  try {
    final bot = await store.botByUsername(p.$2);
    if (bot != null) {
      final chat = await store.openPrivateWith(bot);
      if (start != null) await store.sendText(chat.id, '/start $start');
      if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
      return true;
    }
  } catch (_) {
    // not a bot → a group or channel
  }
  try {
    final info = await store.publicPreview(p.$2);
    if (!context.mounted) return true;
    if (info['is_member'] == true) {
      final chat = await store.getChat((info['chat_id'] as num).toInt());
      if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id, initial: chat)));
    } else {
      Navigator.push(context, MaterialPageRoute(builder: (_) => PublicChatPreviewScreen(info: info)));
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
  return true;
}
