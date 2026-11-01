import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android picture-in-picture: during a video call, leaving the app keeps the call in a small window.
class Pip {
  static const _ch = MethodChannel('talvio/system');

  /// True while the app is shown as the small floating window.
  static final ValueNotifier<bool> active = ValueNotifier(false);
  static bool? _auto;

  static void init() {
    if (!Platform.isAndroid) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged') active.value = call.arguments == true;
      return null;
    });
  }

  /// Turn "go to a small window when I leave the app" on or off.
  static Future<void> setAuto(bool on) async {
    if (!Platform.isAndroid || _auto == on) return;
    _auto = on;
    try {
      await _ch.invokeMethod('pipAuto', {'on': on, 'w': 9, 'h': 16});
    } catch (_) {}
  }

  /// Go to the small window now.
  static Future<bool> enter() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('pipEnter') ?? false;
    } catch (_) {
      return false;
    }
  }
}
