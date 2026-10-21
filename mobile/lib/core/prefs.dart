import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Auto-download photos: 'always' | 'wifi' | 'never'. Videos and files always wait for a tap.
  String autoPhotos = 'always';

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
    autoPhotos = p.getString('auto_photos') ?? 'always';
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

  void setAutoPhotos(String v) {
    autoPhotos = v;
    _p?.setString('auto_photos', v);
    notifyListeners();
  }

  /// Should a photo download by itself right now?
  Future<bool> autoDownloadPhotos() async {
    if (autoPhotos == 'always') return true;
    if (autoPhotos == 'never') return false;
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
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
