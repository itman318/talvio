import 'package:no_screenshot/no_screenshot.dart';

/// Blocks screenshots and screen recording (Android FLAG_SECURE) while at least one
/// sensitive screen is open: vault chats, view-once media, locked chats, protected chats.
/// Counted, so closing one screen doesn't unblock another that is still open.
/// [always] (Privacy → Block screenshots) keeps it on everywhere.
class ScreenGuard {
  ScreenGuard._();

  static int _count = 0;
  /// Protected chats on screen right now (their photos can't be saved from the viewer).
  static int protectedOpen = 0;
  static bool _always = false;

  static void _apply() {
    if (_always || _count > 0) {
      NoScreenshot.instance.screenshotOff().catchError((_) => false);
    } else {
      NoScreenshot.instance.screenshotOn().catchError((_) => false);
    }
  }

  static void setAlways(bool on) {
    if (_always == on) return;
    _always = on;
    _apply();
  }

  static void acquire() {
    if (_count++ == 0) _apply();
  }

  static void release() {
    if (_count == 0) return;
    if (--_count == 0) _apply();
  }
}
