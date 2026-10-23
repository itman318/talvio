import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// Sends uncaught errors to our own server (Admin → App crashes). No third-party service.
/// Each distinct error is sent once per app run; reporting never throws.
class CrashReporter {
  CrashReporter._();

  /// Current access token, so reports can be linked to the user (optional).
  static String? Function()? tokenProvider;

  static final _sent = <String>{};
  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (previous != null) previous(details);
      report(details.exception, details.stack, context: details.context?.toDescription());
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      report(error, stack);
      return true; // handled: don't crash the app for an async error
    };
  }

  static Future<void> report(Object error, StackTrace? stack, {String? context}) async {
    try {
      final message = '${error.runtimeType}: $error'.split('\n').first;
      final st = (stack ?? StackTrace.current).toString();
      final key = '$message|${st.split('\n').take(3).join('|')}';
      if (!_sent.add(key) || _sent.length > 50) return;
      if (kDebugMode) debugPrint('CrashReporter: $message');
      final token = tokenProvider?.call();
      await http
          .post(
            Uri.parse('${AppConfig.apiBase}/client-errors'),
            headers: {'content-type': 'application/json', if (token != null) 'authorization': 'Bearer $token'},
            body: jsonEncode({
              'platform': Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'other'),
              'app_version': AppConfig.appVersion,
              'device': _device(),
              'message': context == null ? message : '$message ($context)',
              'stack': st.length > 12000 ? st.substring(0, 12000) : st,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // never let crash reporting itself crash the app
    }
  }

  static String _device() {
    final v = Platform.operatingSystemVersion;
    return '${Platform.operatingSystem} ${v.length > 80 ? v.substring(0, 80) : v}';
  }
}
