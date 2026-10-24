import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'message_notifications.dart';

/// Firebase Cloud Messaging. If Firebase isn't configured (no google-services.json /
/// GoogleService-Info.plist), push is silently disabled and the app keeps working.
class PushService {
  PushService(this.api);

  final ApiClient api;
  bool _ready = false;
  StreamSubscription<String>? _tokenSub;

  /// Called with a chat id when the user taps a notification.
  void Function(int chatId)? onOpenChat;

  /// Called when the user taps a support-reply notification.
  void Function()? onOpenSupport;

  /// Called when the user taps an incoming-call notification.
  void Function()? onOpenCall;

  Future<void>? _initializing;

  /// Safe to call without waiting: registerDevice() waits for it.
  Future<void> init() => _initializing ??= _init();

  Future<void> _init() async {
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      _ready = true;
    } catch (e) {
      debugPrint('Push disabled (Firebase not configured): $e');
      return;
    }
    // message pushes are data-only on Android: draw them ourselves (with Reply / Mark as read)
    FirebaseMessaging.onBackgroundMessage(firebaseBackgroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleTap);
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      // let the UI build first
      Future.delayed(const Duration(milliseconds: 600), () => _handleTap(initial));
    }
  }

  /// Ask permission and register this device's token with the server (after login).
  Future<void> registerDevice() async {
    try {
      await (_initializing ?? init()).timeout(const Duration(seconds: 15));
    } catch (_) {}
    if (!_ready) return;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await api.put('/me/push-token', {'token': token});
      await _tokenSub?.cancel();
      _tokenSub = FirebaseMessaging.instance.onTokenRefresh.listen((t) {
        api.put('/me/push-token', {'token': t}).catchError((_) => null);
      });
    } catch (e) {
      debugPrint('Push registration failed: $e');
    }
  }

  Future<void> unregister() async {
    await _tokenSub?.cancel();
    _tokenSub = null;
  }

  /// "New login to your account" notification → Devices screen.
  void Function()? onOpenDevices;

  void _handleTap(RemoteMessage m) {
    if (m.data['type'] == 'support') {
      onOpenSupport?.call();
      return;
    }
    if (m.data['type'] == 'call') {
      onOpenCall?.call();
      return;
    }
    if (m.data['type'] == 'new_login') {
      onOpenDevices?.call();
      return;
    }
    final id = int.tryParse('${m.data['chat_id']}');
    if (id != null) onOpenChat?.call(id);
  }
}
