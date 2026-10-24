import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/chat_theme.dart';

/// Device-local preferences: appearance, drafts and app lock.
class AppPrefs extends ChangeNotifier {
  SharedPreferences? _p;

  ThemeMode themeMode = ThemeMode.system;
  double textScale = 1.0;
  final Map<int, String> _drafts = {};

  bool lockEnabled = false;
  bool biometric = false;
  int lockAfterMinutes = 1; // 0 = immediately
  String? _pinHash;

  /// Auto-download, per network: which kinds ('photos', 'videos', 'files') download by themselves.
  Set<String> autoWifi = {'photos', 'videos', 'files'};
  Set<String> autoMobile = {'photos'};

  /// Data saver (for slow or costly internet): photos/videos only on tap, smaller uploads,
  /// no link-preview pictures, lower call video quality.
  bool dataSaver = false;

  // prayer times
  double? prayerLat;
  double? prayerLng;
  String prayerPlace = '';
  int prayerMethod = 0; // CalcMethod index (0 = Karachi)
  bool hanafiAsr = true;
  bool prayerReminders = false;
  bool ramadanReminders = false;
  int hijriAdjust = 0;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    final p = _p!;
    themeMode = ThemeMode.values[(p.getInt('theme_mode') ?? 0).clamp(0, 2).toInt()];
    textScale = p.getDouble('text_scale') ?? 1.0;
    final drafts = p.getString('drafts');
    if (drafts != null) {
      try {
        (jsonDecode(drafts) as Map).forEach((k, v) => _drafts[int.parse('$k')] = '$v');
      } catch (_) {}
    }
    _pinHash = p.getString('pin_hash');
    lockEnabled = _pinHash != null && (p.getBool('lock_enabled') ?? false);
    biometric = p.getBool('lock_biometric') ?? false;
    lockAfterMinutes = p.getInt('lock_after') ?? 1;
    final w = p.getStringList('auto_wifi');
    final m = p.getStringList('auto_mobile');
    if (w != null) autoWifi = w.toSet();
    if (m != null) autoMobile = m.toSet();
    if (w == null && m == null) {
      // older setting: photos 'always' | 'wifi' | 'never'
      final old = p.getString('auto_photos');
      if (old == 'wifi') autoMobile = {};
      if (old == 'never') {
        autoMobile = {};
        autoWifi = {'videos', 'files'};
      }
    }
    dataSaver = p.getBool('data_saver') ?? false;
    prayerLat = p.getDouble('prayer_lat');
    prayerLng = p.getDouble('prayer_lng');
    prayerPlace = p.getString('prayer_place') ?? '';
    prayerMethod = p.getInt('prayer_method') ?? 0;
    hanafiAsr = p.getBool('prayer_hanafi') ?? true;
    prayerReminders = p.getBool('prayer_reminders') ?? false;
    ramadanReminders = p.getBool('ramadan_reminders') ?? false;
    hijriAdjust = p.getInt('hijri_adjust') ?? 0;
    notifyListeners();
  }

  // ------------------------------------------------------------------ appearance
  void setThemeMode(ThemeMode m) {
    themeMode = m;
    _p?.setInt('theme_mode', m.index);
    notifyListeners();
  }

  void setTextScale(double v) {
    textScale = v;
    _p?.setDouble('text_scale', v);
    notifyListeners();
  }

  /// [network] 'wifi' | 'mobile'; [kind] 'photos' | 'videos' | 'files'.
  void setAutoDownload(String network, String kind, bool on) {
    final set = network == 'wifi' ? autoWifi : autoMobile;
    on ? set.add(kind) : set.remove(kind);
    _p?.setStringList(network == 'wifi' ? 'auto_wifi' : 'auto_mobile', set.toList());
    notifyListeners();
  }

  void setPrayerPlace(String name, double lat, double lng) {
    prayerPlace = name;
    prayerLat = lat;
    prayerLng = lng;
    _p?.setString('prayer_place', name);
    _p?.setDouble('prayer_lat', lat);
    _p?.setDouble('prayer_lng', lng);
    notifyListeners();
  }

  void setPrayerOptions({int? method, bool? hanafi, bool? reminders, bool? ramadan, int? hijri}) {
    if (method != null) _p?.setInt('prayer_method', prayerMethod = method);
    if (hanafi != null) _p?.setBool('prayer_hanafi', hanafiAsr = hanafi);
    if (reminders != null) _p?.setBool('prayer_reminders', prayerReminders = reminders);
    if (ramadan != null) _p?.setBool('ramadan_reminders', ramadanReminders = ramadan);
    if (hijri != null) _p?.setInt('hijri_adjust', hijriAdjust = hijri);
    notifyListeners();
  }

  // ------------------------------------------------------------------ chat theme & wallpaper
  /// The look of a chat: its own choice, else the global one, else the default.
  ChatAppearance chatAppearance(int? chatId) {
    if (chatId != null) {
      final own = _p?.getString('chat_look_$chatId');
      if (own != null) return ChatAppearance.fromJson(own);
    }
    return ChatAppearance.fromJson(_p?.getString('chat_look'));
  }

  bool hasOwnChatAppearance(int chatId) => _p?.containsKey('chat_look_$chatId') ?? false;

  /// [chatId] null = all chats. [look] null = back to default (or to the global look for one chat).
  void setChatAppearance(int? chatId, ChatAppearance? look) {
    final key = chatId == null ? 'chat_look' : 'chat_look_$chatId';
    if (look == null) {
      _p?.remove(key);
    } else {
      _p?.setString(key, look.toJson());
    }
    notifyListeners();
  }

  void setDataSaver(bool v) {
    dataSaver = v;
    _p?.setBool('data_saver', v);
    notifyListeners();
  }

  /// Image quality (1-100) and longest side for photos we upload.
  int get uploadQuality => dataSaver ? 60 : 85;
  double get uploadMaxSide => dataSaver ? 1280 : 2560;

  /// Should a photo download by itself right now?
  Future<bool> autoDownloadPhotos() => autoDownload('photos');

  /// Should media of [kind] ('photos' | 'videos' | 'files') download by itself on the current network?
  Future<bool> autoDownload(String kind) async {
    if (dataSaver) return false;
    final onWifi = autoWifi.contains(kind), onMobile = autoMobile.contains(kind);
    if (onWifi && onMobile) return true;
    if (!onWifi && !onMobile) return false;
    try {
      final r = await Connectivity().checkConnectivity();
      final wifi = r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
      return wifi ? onWifi : onMobile;
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------ drafts
  String? draft(int chatId) => _drafts[chatId];

  void setDraft(int chatId, String text) {
    final t = text.trim();
    final had = _drafts.containsKey(chatId);
    if (t.isEmpty) {
      _drafts.remove(chatId);
    } else {
      _drafts[chatId] = text;
    }
    _p?.setString('drafts', jsonEncode(_drafts.map((k, v) => MapEntry('$k', v))));
    if (had != _drafts.containsKey(chatId) || t.isNotEmpty) notifyListeners();
  }

  // ------------------------------------------------------------------ app lock
  static String _hash(String pin) => sha256.convert(utf8.encode('chatapp-lock:$pin')).toString();

  bool checkPin(String pin) => _pinHash != null && _hash(pin) == _pinHash;

  Future<void> enableLock(String pin) async {
    _pinHash = _hash(pin);
    lockEnabled = true;
    await _p?.setString('pin_hash', _pinHash!);
    await _p?.setBool('lock_enabled', true);
    notifyListeners();
  }

  Future<void> disableLock() async {
    _pinHash = null;
    lockEnabled = false;
    biometric = false;
    await _p?.remove('pin_hash');
    await _p?.setBool('lock_enabled', false);
    await _p?.setBool('lock_biometric', false);
    notifyListeners();
  }

  void setBiometric(bool v) {
    biometric = v;
    _p?.setBool('lock_biometric', v);
    notifyListeners();
  }

  void setLockAfter(int minutes) {
    lockAfterMinutes = minutes;
    _p?.setInt('lock_after', minutes);
    notifyListeners();
  }

  /// Clears device-only data on logout (keeps appearance settings).
  Future<void> clearAccountData() async {
    _drafts.clear();
    await _p?.remove('drafts');
    await disableLock();
  }
}
