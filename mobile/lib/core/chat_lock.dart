import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../utils/format.dart';

/// Locked chats: hidden from the chat list and opened only after the phone's fingerprint / face / screen lock.
/// One successful check unlocks all locked chats for a few minutes.
class ChatLock {
  ChatLock._();

  static DateTime? _openUntil;
  static const _window = Duration(minutes: 3);

  static bool get isOpen => _openUntil != null && DateTime.now().isBefore(_openUntil!);

  /// Locks again right away (e.g. the app went to the background).
  static void close() => _openUntil = null;

  /// Asks for the fingerprint (or the phone's screen lock). Returns true when it passed.
  static Future<bool> unlock(BuildContext context, {String reason = 'Unlock your locked chats'}) async {
    if (isOpen) return true;
    final auth = LocalAuthentication();
    try {
      if (!await auth.isDeviceSupported()) {
        if (context.mounted) showInfo(context, 'Set up a fingerprint, face unlock or screen lock on this phone to use chat lock');
        return false;
      }
      final ok = await auth.authenticate(localizedReason: reason);
      if (ok) _openUntil = DateTime.now().add(_window);
      return ok;
    } catch (_) {
      if (context.mounted) showInfo(context, 'Could not check your fingerprint');
      return false;
    }
  }
}
