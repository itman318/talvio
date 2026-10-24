import 'package:no_screenshot/no_screenshot.dart';

/// Blocks screenshots and screen recording (Android FLAG_SECURE) while at least one
/// sensitive screen is open: vault chats, view-once media, locked chats, protected chats.
/// Counted, so closing one screen doesn't unblock another that is still open.
class ScreenGuard {
  ScreenGuard._();

  static int _count = 0;

  static void acquire() {
    if (_count++ == 0) NoScreenshot.instance.screenshotOff().catchError((_) => false);
  }

  static void release() {
    if (_count == 0) return;
    if (--_count == 0) NoScreenshot.instance.screenshotOn().catchError((_) => false);
  }
}
