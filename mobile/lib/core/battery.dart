import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Android battery optimisation can stop Talvio in the background, and then notifications come late
/// or not at all. These helpers check that and open the system screen to allow it.
class BatteryGuard {
  static const _ch = MethodChannel('talvio/system');

  /// True when the phone may put Talvio to sleep (Android only).
  static Future<bool> restricted() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('batteryRestricted') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> ask() async {
    try {
      await _ch.invokeMethod('askBattery');
    } catch (_) {}
  }

  /// Once (and again after a week if still restricted): explain and offer to fix it.
  static Future<void> maybePrompt(BuildContext context) async {
    if (!await restricted()) return;
    final p = await SharedPreferences.getInstance();
    final last = p.getInt('battery.asked') ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - last < const Duration(days: 7).inMilliseconds) return;
    await p.setInt('battery.asked', DateTime.now().millisecondsSinceEpoch);
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.notifications_active_rounded, size: 36),
        title: const Text('Never miss a message'),
        content: const Text('Your phone may pause Talvio in the background to save battery, so messages and calls can arrive late. Allow Talvio to run in the background to get every notification on time.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Allow')),
        ],
      ),
    );
    if (ok == true) await ask();
  }
}
