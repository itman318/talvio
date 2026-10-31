import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings → Notifications → Keep-Alive: a quiet foreground service that keeps Talvio running, so phones
/// that kill apps in the background (Xiaomi, Oppo, Vivo, Realme…) still deliver every message on time.
/// The same service also carries screen sharing in calls, so both go through [apply].
class KeepAlive {
  static bool enabled = false;
  static bool _sharing = false;

  static Future<void> load() async {
    try {
      enabled = (await SharedPreferences.getInstance()).getBool('keep_alive') ?? false;
    } catch (_) {}
  }

  static Future<void> setEnabled(bool on) async {
    enabled = on;
    try {
      await (await SharedPreferences.getInstance()).setBool('keep_alive', on);
    } catch (_) {}
    await apply();
  }

  /// Screen sharing started/stopped in a call.
  static Future<void> setSharing(bool on) async {
    _sharing = on;
    await apply();
  }

  static Future<void> apply() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final types = <ForegroundServiceTypes>[
        if (_sharing) ForegroundServiceTypes.mediaProjection,
        if (enabled) ForegroundServiceTypes.remoteMessaging,
      ];
      if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
      if (types.isEmpty) return;
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: _sharing ? 'screen_share' : 'talvio_keep_alive',
          channelName: _sharing ? 'Screen sharing' : 'Background connection',
          channelDescription: _sharing ? 'Shown while you share your screen in a call' : 'Keeps Talvio connected so messages arrive on time',
          channelImportance: _sharing ? NotificationChannelImportance.LOW : NotificationChannelImportance.MIN,
          priority: _sharing ? NotificationPriority.LOW : NotificationPriority.MIN,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: enabled,
          autoRunOnMyPackageReplaced: enabled,
          allowWakeLock: true,
          allowWifiLock: enabled,
          allowAutoRestart: enabled,
        ),
      );
      await FlutterForegroundTask.startService(
        serviceId: 4711,
        serviceTypes: types,
        notificationTitle: 'Talvio',
        notificationText: _sharing ? 'You are sharing your screen' : 'Connected — you’ll get every message on time',
      );
    } catch (e) {
      debugPrint('Keep-alive: $e');
    }
  }
}
