import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'chat_passcode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Set by the app: a call notification was used — 'answer' / 'open' (call id), or 'callback' (caller id + video).
  static void Function(String action, Map<String, dynamic> payload)? onCallAction;

  /// Notification id of a call (800000+; chats stay below 600000).
  static int callIdFor(int callId) => 800000 + callId % 100000;

  /// Is the ringing call notification on screen right now?
  static Future<bool> callShowing(int callId) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      final list = await plugin.getActiveNotifications();
      return list.any((n) => n.id == callIdFor(callId));
    } catch (_) {
      return false;
    }
  }

  /// The ringing ended (answered, declined, missed): remove the full-screen call notification.
  static Future<void> cancelCall(int callId) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await init();
      await plugin.cancel(callIdFor(callId));
    } catch (_) {}
  }

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
    try {
      await plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
          macOS: DarwinInitializationSettings(requestAlertPermission: true, requestBadgePermission: true, requestSoundPermission: true),
          linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        ),
        onDidReceiveNotificationResponse: _onResponse,
        onDidReceiveBackgroundNotificationResponse: notificationActionInBackground,
      );
    } catch (e) {
      debugPrint('Local notifications unavailable: $e'); // e.g. Windows desktop
    }
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
    final p0 = _payload(r.payload);
    if (p0['kind'] == 'login') {
      if (r.actionId == 'login_revoke') {
        await handleAction(r);
      } else if (r.actionId == null || r.actionId!.isEmpty) {
        onOpenDevices?.call();
      }
      return;
    }
    if (p0['kind'] == 'call' || p0['kind'] == 'call_missed') {
      final a = r.actionId ?? '';
      if (a == 'call_decline' || a == 'reply') {
        await handleAction(r);
        return;
      }
      onCallAction?.call(a.isEmpty ? (p0['kind'] == 'call' ? 'open' : 'open_missed') : a.replaceFirst('call_', ''), p0);
      return;
    }
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
  static String _histKey(int chatId) => 'notif_hist_$chatId';

  /// Adds a message to this chat's notification history (last 8, same message only once).
  static Future<List<Map<String, dynamic>>> _remember(int chatId, Map<String, dynamic> m) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      final list = <Map<String, dynamic>>[];
      final raw = p.getString(_histKey(chatId));
      if (raw != null) {
        for (final x in jsonDecode(raw) as List) {
          list.add(Map<String, dynamic>.from(x as Map));
        }
      }
      // older than a day: start fresh
      list.removeWhere((x) => DateTime.now().millisecondsSinceEpoch - ((x['at'] as num?)?.toInt() ?? 0) > 86400000);
      if (m['id'] == '' || !list.any((x) => x['id'] == m['id'])) list.add(m);
      while (list.length > 8) {
        list.removeAt(0);
      }
      await p.setString(_histKey(chatId), jsonEncode(list));
      return list;
    } catch (_) {
      return [m];
    }
  }

  static Future<void> clearChat(int chatId) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_histKey(chatId));
    } catch (_) {}
    try {
      await init();
      await plugin.cancel(idFor(chatId));
    } catch (_) {}
  }

  /// Draws a message notification from a data-only push.
  static Future<void> show(Map<String, dynamic> data) async {
    if (data['type'] == 'call') return _showCall(data);
    if (data['type'] == 'call_missed') return _showMissed(data);
    if (data['type'] == 'new_login') return _showLogin(data);
    if (data['type'] != 'message' || data['title'] == null) return;
    await init();
    final chatId = int.tryParse('${data['chat_id']}') ?? 0;
    // chats with a passcode: no message text on the lock screen
    try {
      await ChatPasscode.load();
      if (ChatPasscode.has(chatId)) data = {...data, 'body': '🔒 New message'};
    } catch (_) {}
    final canReply = data['reply_token'] != null;
    // Settings → Notifications → Sound / Vibrate. Android fixes sound per channel, so each mix has its own channel.
    var sound = true, vibrate = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.reload();
      sound = p.getBool('notif_sound') ?? true;
      vibrate = p.getBool('notif_vibrate') ?? true;
    } catch (_) {}
    // keep the last few messages of this chat, so the notification shows a conversation (not only the newest line)
    final group = '${data['group']}' == '1';
    final sender = '${data['sender'] ?? data['title']}';
    var text = '${data['body'] ?? ''}';
    if (group && text.startsWith('$sender: ')) text = text.substring(sender.length + 2);
    final history = await _remember(chatId, {
      'id': '${data['message_id'] ?? ''}',
      's': data['chat_title'] != null && !group ? '${data['title']}' : sender,
      't': text,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    final style = (history.length <= 1 && !group) || '${data['locked']}' == '1'
        ? BigTextStyleInformation(text) as StyleInformation
        : MessagingStyleInformation(
            const Person(name: 'You'),
            conversationTitle: group ? '${data['chat_title'] ?? data['title']}' : null,
            groupConversation: group,
            messages: [
              for (final h in history)
                Message('${h['t']}', DateTime.fromMillisecondsSinceEpoch((h['at'] as num).toInt()), Person(name: '${h['s']}', key: '${h['s']}')),
            ],
          );
    final channelId = sound && vibrate ? _channel.channelId : 'messages_${sound ? 's' : 'q'}${vibrate ? 'v' : 'n'}';
    final channelName = sound && vibrate ? _channel.channelName : (sound ? 'Messages (no vibration)' : (vibrate ? 'Messages (no sound)' : 'Messages (silent)'));
    await plugin.show(
      idFor(chatId),
      '${data['title']}',
      '${data['body'] ?? ''}',
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: _channel.channelDescription,
          playSound: sound,
          enableVibration: vibrate,
          importance: _channel.importance,
          priority: _channel.priority,
          category: _channel.category,
          groupKey: 'hushavia.messages',
          styleInformation: style,
          number: history.length,
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

  /// Incoming call while the app is closed or in the background: rings like a phone call,
  /// and opens full screen over the lock screen, with Answer / Decline.
  static Future<void> _showCall(Map<String, dynamic> data) async {
    if (kIsWeb || !Platform.isAndroid) return;
    final callId = int.tryParse('${data['call_id']}');
    if (callId == null) return;
    await init();
    final ringMs = ((int.tryParse('${data['ring_sec']}') ?? 45) * 1000).clamp(10000, 120000);
    final video = '${data['video']}' == '1';
    await plugin.show(
      callIdFor(callId),
      '${data['title'] ?? 'Hushavia'}',
      '${data['body'] ?? (video ? 'Incoming video call' : 'Incoming voice call')}',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'calls_v1',
          'Incoming calls',
          channelDescription: 'Rings when someone calls you',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          playSound: true,
          sound: const UriAndroidNotificationSound('content://settings/system/ringtone'),
          audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
          enableVibration: true,
          vibrationPattern: Int64List.fromList([0, 900, 600, 900, 600, 900]),
          additionalFlags: Int32List.fromList([4]), // keep ringing (FLAG_INSISTENT)
          timeoutAfter: ringMs,
          visibility: NotificationVisibility.public,
          color: const Color(0xFF6D4AFF),
          colorized: true,
          actions: [
            if (data['call_token'] != null)
              const AndroidNotificationAction('call_decline', 'Decline', showsUserInterface: false, cancelNotification: true, titleColor: Color(0xFFE5484D)),
            AndroidNotificationAction('call_answer', video ? 'Answer video' : 'Answer', showsUserInterface: true, cancelNotification: true, titleColor: const Color(0xFF22C55E)),
          ],
        ),
      ),
      payload: jsonEncode({'kind': 'call', 'call_id': callId, 'token': data['call_token'], 'video': video}),
    );
  }

  /// Opens Settings → Devices (set by the app).
  static void Function()? onOpenDevices;

  /// Someone logged in to my account: "Not me — log out" right here, or "It's me".
  static Future<void> _showLogin(Map<String, dynamic> data) async {
    if (kIsWeb || !Platform.isAndroid) return;
    await init();
    final sid = int.tryParse('${data['session_id']}') ?? 0;
    final where = [data['device'], data['place']].where((x) => x != null && '$x'.isNotEmpty).join(' · ');
    await plugin.show(
      850000 + sid % 100000,
      '${data['title'] ?? 'New login to your account'}',
      where.isEmpty ? '${data['body'] ?? ''}' : '$where. Was this you?',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'security',
          'Security',
          channelDescription: 'New logins to your account',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.status,
          color: const Color(0xFFE5484D),
          styleInformation: BigTextStyleInformation(where.isEmpty ? '${data['body'] ?? ''}' : '$where just logged in to your Hushavia account. If it wasn’t you, log it out now and turn on two-step verification.'),
          actions: [
            if (data['login_token'] != null)
              const AndroidNotificationAction('login_revoke', 'Not me — log out', showsUserInterface: false, cancelNotification: true, titleColor: Color(0xFFE5484D)),
            const AndroidNotificationAction('login_ok', 'It’s me', showsUserInterface: false, cancelNotification: true),
          ],
        ),
      ),
      payload: jsonEncode({'kind': 'login', 'session_id': sid, 'token': data['login_token']}),
    );
  }

  /// Missed call: "Call back" and "Message" (type a reply right in the notification).
  static Future<void> _showMissed(Map<String, dynamic> data) async {
    if (kIsWeb || !Platform.isAndroid) return;
    final callId = int.tryParse('${data['call_id']}') ?? 0;
    await init();
    await plugin.cancel(callIdFor(callId));
    final chatId = int.tryParse('${data['chat_id']}');
    final video = '${data['video']}' == '1';
    await plugin.show(
      callIdFor(callId),
      '${data['title'] ?? 'Missed call'}',
      '${data['body'] ?? 'Missed call'}',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'missed_calls',
          'Missed calls',
          channelDescription: 'Calls you didn’t answer',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.missedCall,
          actions: [
            AndroidNotificationAction('call_callback', 'Call back', showsUserInterface: true, cancelNotification: true),
            if (data['reply_token'] != null && chatId != null)
              const AndroidNotificationAction('reply', 'Message',
                  inputs: [AndroidNotificationActionInput(label: 'Message')], showsUserInterface: false, cancelNotification: true),
          ],
        ),
      ),
      payload: jsonEncode({
        'kind': 'call_missed',
        'call_id': callId,
        'chat_id': chatId,
        'caller_id': int.tryParse('${data['caller_id']}'),
        'video': video,
        'token': data['reply_token'],
      }),
    );
  }

  /// Reply / Mark as read — works in the background, without the app's login session.
  static Future<void> handleAction(NotificationResponse r) async {
    final p = _payload(r.payload);
    final token = p['token'];
    final chatId = int.tryParse('${p['chat_id']}') ?? 0;
    if (token == null) return;
    try {
      if (r.actionId == 'login_revoke') {
        await http.post(Uri.parse('${AppConfig.apiBase}/notify/login-revoke'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({'token': token}));
        return;
      }
      if (r.actionId == 'call_decline') {
        await plugin.cancel(callIdFor(int.tryParse('${p['call_id']}') ?? 0));
        await http.post(Uri.parse('${AppConfig.apiBase}/notify/call-decline'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({'token': token}));
        return;
      }
      if (r.actionId == 'reply' && p['kind'] == 'call_missed') {
        final text = (r.input ?? '').trim();
        if (text.isEmpty) return;
        await http.post(Uri.parse('${AppConfig.apiBase}/notify/reply'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'token': token, 'text': text, 'client_id': 'n${DateTime.now().microsecondsSinceEpoch}'}));
        await plugin.cancel(callIdFor(int.tryParse('${p['call_id']}') ?? 0));
        return;
      }
      if (r.actionId == 'reply') {
        final text = (r.input ?? '').trim();
        if (text.isEmpty) return;
        await http.post(Uri.parse('${AppConfig.apiBase}/notify/reply'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'token': token, 'text': text, 'client_id': 'n${DateTime.now().microsecondsSinceEpoch}'}));
        await plugin.cancel(idFor(chatId));
        await clearChat(chatId);
      } else if (r.actionId == 'read') {
        await http.post(Uri.parse('${AppConfig.apiBase}/notify/read'),
            headers: {'Content-Type': 'application/json'}, body: jsonEncode({'token': token, 'message_id': p['message_id']}));
        await clearChat(chatId);
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
