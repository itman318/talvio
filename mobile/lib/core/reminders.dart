import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'message_notifications.dart';

/// "Remind me" on a message: a notification on this phone at the chosen time (works offline).
class Reminder {
  Reminder({required this.id, required this.chatId, required this.messageId, required this.chatTitle, required this.preview, required this.at});
  final int id;
  final int chatId;
  final int messageId;
  final String chatTitle;
  final String preview;
  final DateTime at;

  Map<String, dynamic> toJson() => {'id': id, 'c': chatId, 'm': messageId, 't': chatTitle, 'p': preview, 'at': at.toIso8601String()};
  static Reminder fromJson(Map j) => Reminder(
        id: (j['id'] as num).toInt(),
        chatId: (j['c'] as num).toInt(),
        messageId: (j['m'] as num).toInt(),
        chatTitle: '${j['t'] ?? ''}',
        preview: '${j['p'] ?? ''}',
        at: DateTime.parse('${j['at']}'),
      );
}

class Reminders {
  Reminders._();

  static const _key = 'message_reminders';
  static bool _tz = false;

  /// Notification ids 700000+ (chat ids are used for message notifications, 900000+ for prayers).
  static int newId() => 700000 + DateTime.now().millisecondsSinceEpoch % 190000;

  static Future<List<Reminder>> _all() async {
    final p = await SharedPreferences.getInstance();
    try {
      return (jsonDecode(p.getString(_key) ?? '[]') as List).map((e) => Reminder.fromJson(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<Reminder> l) async =>
      (await SharedPreferences.getInstance()).setString(_key, jsonEncode(l.map((r) => r.toJson()).toList()));

  static Future<List<Reminder>> upcoming() async {
    final now = DateTime.now();
    final l = (await _all()).where((r) => r.at.isAfter(now)).toList()..sort((a, b) => a.at.compareTo(b.at));
    await _save(l); // drop the past ones
    return l;
  }

  /// Returns false when notifications are not allowed.
  static Future<bool> add(Reminder r) async {
    await MessageNotifications.init();
    if (!_tz) {
      tzdata.initializeTimeZones();
      _tz = true;
    }
    final plugin = MessageNotifications.plugin;
    final allowed = await plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission() ?? true;
    if (!allowed) return false;
    await plugin.zonedSchedule(
      r.id,
      'Reminder · ${r.chatTitle}',
      r.preview.isEmpty ? 'Tap to open the message' : r.preview,
      tz.TZDateTime.from(r.at.toUtc(), tz.UTC),
      const NotificationDetails(
        android: AndroidNotificationDetails('reminders', 'Reminders', channelDescription: 'Message reminders you set', importance: Importance.high, priority: Priority.high),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      payload: jsonEncode({'chat_id': r.chatId, 'message_id': r.messageId}),
    );
    await _save([...await upcoming(), r]);
    return true;
  }

  static Future<void> cancel(int id) async {
    await MessageNotifications.init();
    await MessageNotifications.plugin.cancel(id);
    await _save((await _all()).where((r) => r.id != id).toList());
  }
}
