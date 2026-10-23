import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'prayer_times.dart';
import 'prefs.dart';

/// Local notifications for prayer times (and Sehri/Iftar in Ramadan) for the next 7 days.
/// Scheduled on the phone — they work offline and without the server.
class PrayerReminders {
  PrayerReminders._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static const _channel = AndroidNotificationDetails(
    'prayer_times',
    'Prayer times',
    channelDescription: 'Reminders at prayer times and for Sehri / Iftar',
    importance: Importance.high,
    priority: Priority.high,
  );

  static Future<void> _init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.UTC); // we schedule absolute instants, so UTC is fine
    await _plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
    ));
    _ready = true;
  }

  static Future<bool> requestPermission() async {
    await _init();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    final a = await android?.requestNotificationsPermission();
    final i = await ios?.requestPermissions(alert: true, sound: true);
    return (a ?? true) && (i ?? true);
  }

  /// Re-plans all reminders from the current settings (call on start and when settings change).
  static Future<void> reschedule(AppPrefs p) async {
    try {
      await _init();
      await _plugin.cancelAll();
      if ((!p.prayerReminders && !p.ramadanReminders) || p.prayerLat == null || p.prayerLng == null) return;
      final now = DateTime.now();
      var id = 1;
      for (var d = 0; d < 7; d++) {
        final day = DateTime(now.year, now.month, now.day).add(Duration(days: d));
        final t = prayerTimes(day, lat: p.prayerLat!, lng: p.prayerLng!, method: CalcMethod.values[p.prayerMethod], hanafiAsr: p.hanafiAsr);
        final ramadan = hijriFor(day, adjustDays: p.hijriAdjust).isRamadan;
        final plan = <(DateTime, String, String)>[];
        if (p.prayerReminders) {
          for (final (name, time) in t.prayers) {
            plan.add((time, '$name time', 'It is time for $name${p.prayerPlace.isEmpty ? '' : ' in ${p.prayerPlace}'}.'));
          }
        }
        if (p.ramadanReminders && ramadan) {
          plan.add((t.fajr.subtract(const Duration(minutes: 30)), 'Sehri ends in 30 minutes', 'Sehri until ${_hm(t.fajr)}.'));
          plan.add((t.maghrib, 'Iftar time', 'Iftar now — ${_hm(t.maghrib)}. Ramadan Mubarak!'));
        }
        for (final (when, title, body) in plan) {
          if (!when.isAfter(now)) continue;
          await _plugin.zonedSchedule(
            id++,
            title,
            body,
            tz.TZDateTime.from(when.toUtc(), tz.UTC),
            const NotificationDetails(android: _channel, iOS: DarwinNotificationDetails()),
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          );
        }
      }
    } catch (e) {
      debugPrint('Prayer reminders: $e');
    }
  }

  static String _hm(DateTime t) => '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}
