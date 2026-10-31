import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// This phone's notification choices (Settings → Notifications): what happens while the app is open,
/// how calls ring, and what the Chats badge counts. Loaded once at start; changes notify listeners.
class NotifPrefs extends ChangeNotifier {
  NotifPrefs._();
  static final instance = NotifPrefs._();

  bool inAppBanner = true;
  bool inAppSound = true;
  bool inAppVibrate = true;
  bool callRing = true;
  bool callVibrate = true;
  bool badgeMuted = false; // count muted chats too
  bool badgeChats = false; // count chats instead of messages

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      inAppBanner = p.getBool('inapp_banner') ?? true;
      inAppSound = p.getBool('inapp_sound') ?? true;
      inAppVibrate = p.getBool('inapp_vibrate') ?? true;
      callRing = p.getBool('call_ring') ?? true;
      callVibrate = p.getBool('call_vibrate') ?? true;
      badgeMuted = p.getBool('badge_muted') ?? false;
      badgeChats = p.getBool('badge_chats') ?? false;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> set(String key, bool v) async {
    switch (key) {
      case 'inapp_banner':
        inAppBanner = v;
      case 'inapp_sound':
        inAppSound = v;
      case 'inapp_vibrate':
        inAppVibrate = v;
      case 'call_ring':
        callRing = v;
      case 'call_vibrate':
        callVibrate = v;
      case 'badge_muted':
        badgeMuted = v;
      case 'badge_chats':
        badgeChats = v;
    }
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setBool(key, v);
    } catch (_) {}
  }
}
