import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'chat_passcode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Message notifications drawn by the app (Android): grouped per chat, with
/// "Reply" (type right in the notification) and "Mark as read" buttons.
/// The push carries a reply token that allows only these two actions in that chat.
class MessageNotifications {
  MessageNotifications._();

  static final plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// Set by the app (main isolate): open a chat when a notification is tapped.
  static void Function(int chatId)? onOpenChat;

  static const _channel = AndroidNotificationDetails(
    'messages',
    'Messages',
    channelDescription: 'New messages in your chats',
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.message,
  );

  /// One shared initialisation for every local notification in the app.
  static Future<void> init() async {
    if (_ready) return;
    _ready = true;
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
      ),
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: notificationActionInBackground,
    );
  }

  /// Tapped a notification that started the app.
  static Future<void> handleLaunch() async {
    try {
      await init();
      final d = await plugin.getNotificationAppLaunchDetails();
      final r = d?.notificationResponse;
      if (d?.didNotificationLaunchApp == true && r != null) await _onResponse(r);
    } catch (_) {}
  }

  static Future<void> _onResponse(NotificationResponse r) async {
    if (r.actionId == null || r.actionId!.isEmpty) {
      final p = _payload(r.payload);
      final id = int.tryParse('${p['chat_id']}');
      if (id != null) onOpenChat?.call(id);
      return;
    }
    await handleAction(r);
  }

  static Map<String, dynamic> _payload(String? s) {
    try {
      return Map<String, dynamic>.from(jsonDecode(s ?? '{}') as Map);
    } catch (_) {
      return {};
    }
  }

  /// Notification id of a chat (below 600000: reminders use 700000+, prayer times 900000+).
  static int idFor(int chatId) => chatId % 600000;

  /// Removes a chat's notification (the chat was opened).
  static Future<void> clearChat(int chatId) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await init();
      await plugin.cancel(idFor(chatId));
    } catch (_) {}
  }

  /// Draws a message notification from a data-only push.
  static Future<void> show(Map<String, dynamic> data) async {
    if (data['type'] != 'message' || data['title'] == null) return;
    await init();
    final chatId = int.tryParse('${data['chat_id']}') ?? 0;
    // chats with a passcode: no message text on the lock screen
    try {
      await ChatPasscode.load();
      if (ChatPasscode.has(chatId)) data = {...data, 'body': '🔒 New message'};
    } catch (_) {}
    final canReply = data['reply_token'] != null;
    await plugin.show(
      idFor(chatId),
      '${data['title']}',
      '${data['body'] ?? ''}',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.channelId,
          _channel.channelName,
          channelDescription: _channel.channelDescription,
          importance: _channel.importance,
          priority: _channel.priority,
          category: _channel.category,
          groupKey: 'talvio.messages',
          styleInformation: BigTextStyleInformation('${data['body'] ?? ''}'),
          actions: canReply
              ? const [
                  AndroidNotificationAction('reply', 'Reply',
                      inputs: [AndroidNotificationActionInput(label: 'Message')], showsUserInterface: false, cancelNotification: false),
                  AndroidNotificationAction('read', 'Mark as read', showsUserInterface: false, cancelNotification: true),
                ]
              : null,
        ),
        iOS: const DarwinNotificationDetails(threadIdentifier: 'messages'),
      ),
      payload: jsonEncode({'chat_id': chatId, 'message_id': data['message_id'], 'token': data['reply_token']}),
    );
  }

  /// Reply / Mark as read — works in the background, without the app's login session.
  static Future<void> handleAction(NotificationResponse r) async {
    final p = _payload(r.payload);
    final token = p['token'];
    final chatId = int.tryParse('${p['chat_id']}') ?? 0;
    if (token == null) return;
    try {
      if (r.actionId == 'reply') {
        final text = (r.input ?? '').trim();
        if (text.isEmpty) return;
        await http.post(Uri.parse('${AppConfig.apiBase}/notify/reply'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'token': token, 'text': text, 'client_id': 'n${DateTime.now().microsecondsSinceEpoch}'}));
        await plugin.cancel(idFor(chatId));
      } else if (r.actionId == 'read') {
        await http.post(Uri.parse('${AppConfig.apiBase}/notify/read'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({'token': token, 'message_id': p['message_id']}));
        await plugin.cancel(idFor(chatId));
      }
    } catch (e) {
      debugPrint('notification action failed: $e');
    }
  }
}

/// Runs in a background isolate when Reply / Mark as read is pressed while the app is closed.
@pragma('vm:entry-point')
void notificationActionInBackground(NotificationResponse r) {
  MessageNotifications.handleAction(r);
}

/// FCM data message while the app is in the background or closed.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundMessage(RemoteMessage m) async {
  await MessageNotifications.show(m.data);
}
