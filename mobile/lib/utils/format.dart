import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/api_client.dart';
import '../models/models.dart';
import '../state/chat_store.dart';

String chatListTime(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return DateFormat.Hm().format(t);
  if (diff < 7) return DateFormat.E().format(t);
  if (t.year == now.year) return DateFormat('d MMM').format(t);
  return DateFormat('dd/MM/yy').format(t);
}

String messageTime(DateTime t) => DateFormat.Hm().format(t);

/// 950 → "950", 1200 → "1.2K", 3400000 → "3.4M"
String compactNumber(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}K';
  return '${(n / 1000000).toStringAsFixed(1)}M';
}

String dateSeparator(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (t.year == now.year) return DateFormat('d MMMM').format(t);
  return DateFormat('d MMMM y').format(t);
}

String lastSeenText(AppUser u) {
  if (u.deleted) return 'deleted account';
  if (u.online) return 'online';
  if (u.lastSeenHidden || u.lastSeen == null) return 'last seen recently';
  final t = u.lastSeen!;
  final mins = DateTime.now().difference(t).inMinutes;
  if (mins < 1) return 'last seen just now';
  if (mins < 60) return 'last seen $mins min ago';
  final now = DateTime.now();
  if (t.year == now.year && t.month == now.month && t.day == now.day) return 'last seen at ${DateFormat.Hm().format(t)}';
  final yesterday = now.subtract(const Duration(days: 1));
  if (t.year == yesterday.year && t.month == yesterday.month && t.day == yesterday.day) {
    return 'last seen yesterday at ${DateFormat.Hm().format(t)}';
  }
  return 'last seen ${DateFormat('d MMM').format(t)}';
}

String fileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

String duration(int seconds) {
  final m = seconds ~/ 60;
  final s = seconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// Human text for a system message ("Ali added Bilal").
String systemText(Message m, ChatStore store) {
  final actor = store.userName(m.senderId);
  final meta = m.meta ?? {};
  String who(dynamic id) => store.userName(id is num ? id.toInt() : null);
  switch (meta['event']) {
    case 'group_created':
      return '$actor created the group “${meta['title'] ?? ''}”';
    case 'channel_created':
      return 'Channel “${meta['title'] ?? ''}” created';
    case 'title_changed':
      return '$actor changed the group name to “${meta['title'] ?? ''}”';
    case 'disappearing_changed':
      final secs = (meta['seconds'] as num?)?.toInt() ?? 0;
      return secs == 0 ? '$actor turned off disappearing messages' : '$actor set messages to disappear after ${disappearLabel(secs)}';
    case 'photo_changed':
      return '$actor changed the group photo';
    case 'photo_removed':
      return '$actor removed the group photo';
    case 'members_added':
      final ids = (meta['user_ids'] as List? ?? []);
      if (ids.length == 1) return '$actor added ${who(ids.first)}';
      return '$actor added ${ids.length} members';
    case 'member_removed':
      return '$actor removed ${who(meta['user_id'])}';
    case 'member_left':
      return '${who(meta['user_id'])} left the group';
    case 'member_joined':
      return '${who(meta['user_id'])} joined the group via invite link';
    case 'owner_changed':
      return '${who(meta['user_id'])} is now the group owner';
    default:
      return 'Group updated';
  }
}

void showError(BuildContext context, Object error) {
  final text = error is ApiException ? error.message : 'Something went wrong';
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

void showInfo(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'OK', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok, style: danger ? TextStyle(color: Theme.of(ctx).colorScheme.error) : null),
        ),
      ],
    ),
  );
  return r == true;
}

/// "1 hour", "24 hours", "7 days", "90 days" for the disappearing-messages timer.
String disappearLabel(int seconds) {
  if (seconds <= 0) return 'Off';
  if (seconds < 86400) return '${seconds ~/ 3600} hour${seconds ~/ 3600 == 1 ? '' : 's'}';
  if (seconds == 86400) return '24 hours';
  final d = seconds ~/ 86400;
  return '$d day${d == 1 ? '' : 's'}';
}
